#!/usr/bin/env ruby
require "octokit"
require "yaml"
require "git_diff_parser"

Octokit.auto_paginate = true
config = YAML.load_file("ghbot.yaml")
client = Octokit::Client.new(config["credentials"] || {})

def bot_comments client, repo_name, pr
    client.issue_comments(repo_name, pr).reject {|c| c[:body].strip.match(/[*]CFME QE Bot[*]$/).nil? }
end

def landscape_comments client, repo_name, pr
    client.issue_comments(repo_name, pr).reject {|c| c[:body].strip.match(/\[Code Health\]/).nil? }
end

def old_landscape_comments client, repo_name, pr
    comments = landscape_comments client, repo_name, pr
    if comments.length <= 1
        []  # There is no comment or only one, which we obviously don't want to delete
    else
        comments.take(comments.length - 1)
    end
end

def remove_old_landscape_comments client, repo_name, pr
    old_landscape_comments(client, repo_name, pr).each do |comment|
        client.delete_comment repo_name, comment.id
    end.length
end

def get_lint_comments_hashes client, repo_name, pr
    client.issue_comments(repo_name, pr).map(&:body).map {|c| c.strip.match(/^Lint report for commit ([a-fA-F0-9]+):/)} .reject {|h| h.nil?} .map {|c| c[1]}
end

def remove_old_lint_comments client, repo_name, pr
    bot_comments(client, repo_name, pr).reject {|c| c[:body].strip.match(/^Lint report for commit ([a-fA-F0-9]+):/).nil? } .each { |comment| client.delete_comment repo_name, comment.id }
end

def remove_old_rebase_comments client, repo_name, pr
    bot_comments(client, repo_name, pr).reject {|c| c[:body].strip.match(/^Would you mind rebasing this Pull Request against latest master, please/).nil? } .each { |comment| client.delete_comment repo_name, comment.id }
end

def has_req_comment client, repo_name, pr
    (bot_comments(client, repo_name, pr).map {|c| c[:body].strip.match(/^Requirements have changed/)} .reject {|h| h.nil?} .length) > 0
end

(config["repositories"] || {}).each do |repo_name, repo_data|
    puts "Processing repository #{repo_name} ->"
    repo = client.repository repo_name
    labels = client.labels(repo_name).map { |lbl| lbl[:name] }
    needs_rebase_label = repo_data["needs_rebase"]
    doc_label = repo_data["doc"]
    wip_label = repo_data["wip"]
    wiptest_label = repo_data["wiptest"]
    flake = repo_data["flake"]
    # Exctract data for flaking
    unless flake.nil?
        needs_flake = flake["needs"]
        flake_ok = flake["ok"]
        flake_params = flake["params"] || ""
        if needs_flake.nil? || flake_ok.nil?
            flake = false
        else
            flake = true
        end
    else
        flake = false
    end
    client.pull_requests(repo_name, :state => "open").each do |pull_request|
        # some variables
        # We have to retrieve full PR object here
        pull_request = client.pull_request repo_name, pull_request.number
        pr_files = client.pull_request_files repo_name, pull_request.number
        puts " Processing PR\##{pull_request.number}@#{repo_name} ->"
        # Read labels, names only
        pr_labels = client.labels_for_issue(repo_name, pull_request.number).map { |lbl| lbl[:name] }
        # Needs rebase
        if needs_rebase_label != nil && labels.include?(needs_rebase_label) && pull_request.mergeable_state != "unknown"  # Border case
            # Apply label if needed
            if pull_request.mergeable
                puts "  #{pull_request.number} is mergeable"
                if pr_labels.include? needs_rebase_label
                    puts "   remove '#{needs_rebase_label}' from #{pull_request.number}"
                    client.remove_label repo_name, pull_request.number, needs_rebase_label
                    remove_old_rebase_comments client, repo_name, pull_request.number
                end
            else
                puts "  #{pull_request.number} is not mergeable"
                unless pr_labels.include? needs_rebase_label
                    puts "   add '#{needs_rebase_label}' from #{pull_request.number}"
                    client.add_labels_to_an_issue repo_name, pull_request.number, [needs_rebase_label]
                    # Comment "Would you mind rebasing this Pull Request against latest master, please?"
                    client.add_comment repo_name, pull_request.number, "Would you mind rebasing this Pull Request against latest master, please? :trollface:\n*CFME QE Bot*"
                end
            end
        end
        # Flaking
        linted = get_lint_comments_hashes client, repo_name, pull_request.number
        if flake && (! linted.include? pull_request.head.sha)
            clone_url = pull_request.head.repo.git_url
            branch = pull_request.head.ref
            `mkdir -p /tmp/ghbot; rm -rf /tmp/ghbot/clone`
            `git clone -b #{branch} #{clone_url} /tmp/ghbot/clone`
            flakes = {}
            pr_files.each do |file|
                patch = GitDiffParser::Patch.new(file.patch)
                changed_lines = patch.changed_lines.collect(&:number)
                removed_lines = file.patch.split(/\n/).select {|line| line =~ /^-/} .collect { |line| line.gsub(/^-/, '')}
                if file.filename =~ /[.]py$/
                    flake_result = `cd /tmp/ghbot/clone && flake8 #{flake_params} #{file.filename}`.strip
                    flakes[file.filename] = flake_result.split(/(\n)/).collect do |line|
                        line_match = line.match /^([^:]+):([^:]+):([^:]+):\s+([A-Z][0-9]+)\s+(.*?)$/
                        next nil if line_match.nil?
                        lineno = line_match[2].to_i
                        colno = line_match[3].to_i
                        flake_code = line_match[4]
                        flake_message = line_match[5]
                        force_add = false
                        if flake_code == 'F401'
                            # This is an unused import, this needs cross-matching, otherwise it will get filtered out
                            import_match = flake_message.match /^'([^']+)' imported but unused$/
                            unless import_match.nil?
                                matched_import = import_match[1]
                                if removed_lines.select {|line| line.match(/\b#{matched_import}\b/)} .size > 0
                                    # This proves that the unused import can be caused by this PR
                                    # because the name of the import is present in the removed lines
                                    force_add = true
                                end
                            end
                        elsif flake_code == 'E303'
                            number_match = flake_message.match /^too many blank lines\s+\((\d+)\)$/
                            unless number_match.nil?
                                line_count = number_match[1].to_i
                                # Now get the lines that are the many blank lines. An array of ints
                                line_candidates = ((lineno - line_count)..lineno).to_a
                                # Now let's try to find whether any of the blank lines is in the changed lines
                                if line_candidates.select {|l_no| changed_lines.include?(l_no) } .size > 0
                                    # Yes it is, nag the person.
                                    force_add = true
                                end
                            end
                        end
                        if changed_lines.include?(lineno) || force_add
                            # Touched by this PR, let's nag
                            [lineno, colno, flake_code, flake_message]
                        else
                            nil
                        end
                    end.reject(&:nil?)
                elsif file.filename =~ /[.]rst$/
                    flake_result = `cd /tmp/ghbot/clone && rstcheck #{file.filename} 2>&1`.strip
                    flakes[file.filename] = flake_result.split(/(\n)/).collect do |line|
                        line_match = line.match(/^([^:]+):([^:]+):\s*\(([^)]+)\)\s*(.*?)$/)
                        next nil if line_match.nil?
                        lineno = line_match[2].to_i
                        colno = nil
                        flake_code = line_match[3]
                        flake_message = line_match[4]
                        if changed_lines.include?(lineno)
                            # Touched by this PR, let's nag
                            [lineno, colno, flake_code, flake_message]
                        else
                            nil
                        end
                    end.reject(&:nil?)
                end
            end
            any_lint_issues = flakes.values.collect(&:length).sort.uniq.reject {|n| n == 0} .length > 0

            # label
            if any_lint_issues
                puts "  flake not ok:"
                if pr_labels.include? flake_ok
                    client.remove_label repo_name, pull_request.number, flake_ok
                end
                unless pr_labels.include? needs_flake
                    client.add_labels_to_an_issue repo_name, pull_request.number, [needs_flake]
                end
            else
                # Flake ok
                puts "  flake ok!"
                if pr_labels.include?(needs_flake)
                    client.remove_label repo_name, pull_request.number, needs_flake
                end

                unless pr_labels.include?(flake_ok)
                    client.add_labels_to_an_issue repo_name, pull_request.number, [flake_ok]
                end
            end

            # Build the comment
            unless linted.include? pull_request.head.sha
                puts "Adding lint comment for #{pull_request.head.sha}"
                remove_old_lint_comments client, repo_name, pull_request.number
                comment_body = "Lint report for commit #{pull_request.head.sha}:\n"
                flakes.each do |filename, data|
                    next unless any_lint_issues
                    next if data.length == 0
                    comment_body << "\n`#{filename}`:\n"
                    data.each do |lineno, colno, flake_code, flake_message|
                        icon = ':red_circle:'  # If nothing else applies
                        icon = ':bangbang:' if flake_code =~ /^E[0-9]|^SEVERE/  # Error
                        icon = ':heavy_exclamation_mark:' if flake_code =~ /^W[0-9]|^ERROR/  # Warning
                        icon = ':warning:' if flake_code =~ /^WARNING/  # Warning of rstcheck
                        icon = ':grey_exclamation:' if flake_code =~ /^P[0-9]|^T[0-9]|^S[0-9]|^INFO/  # Bad practices
                        if colno.nil?
                            comment_body << "- #{icon} Line #{lineno}: **#{flake_code}** *#{flake_message}*\n"
                        else
                            comment_body << "- #{icon} Line #{lineno}:#{colno}: **#{flake_code}** *#{flake_message}*\n"
                        end
                    end
                end
                comment_body << "\n"
                if any_lint_issues
                    comment_body << "Please, rectify these issues :smirk: .\n"
                else
                    comment_body << "Everything seems all right :smile: .\n"
                end
                comment_body << "*CFME QE Bot*"

                # Add the comment
                remove_old_lint_comments client, repo_name, pull_request.number
                client.add_comment repo_name, pull_request.number, comment_body
            end
        end
        # WIP'ing (ordinary people do not have access to the labels)
        title = pull_request[:title].downcase.gsub /\s+/, " "

        if title.include? "[wip]"
            puts "  #{pull_request.number} is WIP"
            unless pr_labels.include? wip_label
                puts "   add '#{wip_label}' from #{pull_request.number}"
                client.add_labels_to_an_issue repo_name, pull_request.number, [wip_label]
            end
        else
            puts "  #{pull_request.number} is not WIP"
            if pr_labels.include? wip_label
                puts "   remove '#{wip_label}' from #{pull_request.number}"
                client.remove_label repo_name, pull_request.number, wip_label
            end
        end

        if title.include? "[doc]"
            puts "  #{pull_request.number} is with documentation"
            unless pr_labels.include? doc_label
                puts "   add '#{doc_label}' from #{pull_request.number}"
                client.add_labels_to_an_issue repo_name, pull_request.number, [doc_label]
            end
        else
            puts "  #{pull_request.number} is not with documentation"
            if pr_labels.include? doc_label
                puts "   remove '#{doc_label}' from #{pull_request.number}"
                client.remove_label repo_name, pull_request.number, doc_label
            end
        end

        if wiptest_label
            if title.include? "[wiptest]"
                puts "  #{pull_request.number} is WIPTEST"
                unless pr_labels.include? wiptest_label
                    puts "   add '#{wiptest_label}' from #{pull_request.number}"
                    client.add_labels_to_an_issue repo_name, pull_request.number, [wiptest_label]
                end
            else
                puts "  #{pull_request.number} is not WIPTEST"
                if pr_labels.include? wiptest_label
                    puts "   remove '#{wiptest_label}' from #{pull_request.number}"
                    client.remove_label repo_name, pull_request.number, wiptest_label
                end
            end
        end

        # requirements.txt change
        files = client.pull_request_files repo_name, pull_request.number, :per_page => 1000
        if files.map(&:filename).include? "requirements.txt"
            # requirements changed
            #if ! has_req_comment client, repo_name, pull_request.number
            #    puts "   add req comment to  #{pull_request.number}"
            #    client.add_comment repo_name, pull_request.number, "Requirements have changed. @seandst , @psav ?\n*CFME QE Bot*"
            #end
        end

        # Remove old landscape comments
        n_comments = remove_old_landscape_comments client, repo_name, pull_request.number
        puts "Removed #{n_comments} landscape.io comments"
    end
end

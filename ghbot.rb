#!/usr/bin/env ruby
require "octokit"
require "yaml"

config = YAML.load_file("ghbot.yaml")
client = Octokit::Client.new(config["credentials"] || {})

def bot_comments client, repo_name, pr
    client.issue_comments(repo_name, pr).reject {|c| c[:body].strip.match(/[*]CFME QE Bot[*]$/).nil? }
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

(config["repositories"] || {}).each do |repo_name, repo_data|
    puts "Processing repository #{repo_name} ->"
    repo = client.repository repo_name
    labels = client.labels(repo_name).map { |lbl| lbl[:name] }
    needs_rebase_label = repo_data["needs_rebase"]
    wip_label = repo_data["wip"]
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
                    client.add_comment repo_name, pull_request.number, "Would you mind rebasing this Pull Request against latest master, please?\n*CFME QE Bot*"
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
            result = `cd /tmp/ghbot/clone && flake8 #{flake_params} .`
            if result.strip.empty?
                # Flake ok
                puts "  flake ok!"
                if pr_labels.include?(needs_flake)
                    client.remove_label repo_name, pull_request.number, needs_flake
                end

                unless pr_labels.include?(flake_ok)
                    client.add_labels_to_an_issue repo_name, pull_request.number, [flake_ok]
                end

                unless linted.include? pull_request.head.sha
                    puts "Adding lint comment for #{pull_request.head.sha}"
                    remove_old_lint_comments client, repo_name, pull_request.number
                    client.add_comment repo_name, pull_request.number, "Lint report for commit #{pull_request.head.sha}:\n:godmode: All seems good! :cake: :punch: :cookie: \n*CFME QE Bot*"
                end
            else
                puts "  flake not ok:"
                puts result
                if pr_labels.include? flake_ok
                    client.remove_label repo_name, pull_request.number, flake_ok
                end
                unless pr_labels.include? needs_flake
                    client.add_labels_to_an_issue repo_name, pull_request.number, [needs_flake]
                end
                unless linted.include? pull_request.head.sha
                    puts "Adding lint comment for #{pull_request.head.sha}"
                    remove_old_lint_comments client, repo_name, pull_request.number
                    client.add_comment repo_name, pull_request.number, "Lint report for commit #{pull_request.head.sha}:\n:hurtrealbad: There were some flake issues that need to be resolved in order to merge the pull request:\n```\n#{result.strip}\n```\n*CFME QE Bot*"
                end
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
    end
end

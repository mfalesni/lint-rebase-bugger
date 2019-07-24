#!/usr/bin/env bash

SLEEP=300

hash virtualenv || {
    echo "Please install virtualenv"
    exit 1
}
ruby -e "require 'octokit'" >/dev/null 2>&1 || {
    echo "Please install Octokit gem"
    exit 2
}

ruby -e "require 'git_diff_parser'" >/dev/null 2>&1 || {
    echo "Please install git_diff_parser gem"
    exit 2
}

if [ ! -e ./ghbot_ve_py3/bin/activate ] ;
then
    python3 -m venv ghbot_ve_py3
    . ./ghbot_ve_py3/bin/activate
    pip install flake8
else
. ./ghbot_ve_py3/bin/activate
fi

while true ;
do
    git pull origin master
    ./ghbot.rb
    sleep $SLEEP
done

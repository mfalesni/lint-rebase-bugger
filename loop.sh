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

if [ ! -e ./ghbot_ve/bin/activate ] ;
then
    virtualenv ghbot_ve
    . ./ghbot_ve/bin/activate
    pip install flake8
else
. ./ghbot_ve/bin/activate
fi

while true ;
do
    git pull origin master
    ./ghbot.rb
    sleep $SLEEP
done

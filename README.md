# GitHub Package Installer

This is a github package manager that will allow you to install and manage pre-compiled binaries from github releases.
It allows you to provice a  GitHub repository in the form of owner/repo-name, and it will automatically fetch, validate and install the binaries
It is meant to simplify the 
I used this as practice while learning bash, so there are bound to be errors. 

## Why? What is it all for?
I found myself having to install brew or similar if I wanted the latest version of a binary.
For some cli tools that I use freaquently, such as zoxide or fzf, latest apt versions seeem to be missing a lot of features.
Manually installing and managing these files is a chore.

This is meant to be used for (ideally) statically linked, standalone binaries. 
It will not work with tools that need systemd, or need deeper kernel access. In these cases, use the tools developers provided to install them. 

## Is it dangerous?
The script does not make changes to system that are not reversible, and does not write to any system directories.
All binaries are installed to $HOME/.local/bin
Completions and man pages are installed  to $HOME/.local/share

It maintains a database of files it has copied, these are removed when package is removed with ghpm remove [package].

## Features
- allows installation of pre-compiled binaries from github
- update and remove functions.
- validates binaries before they are installed

## Dependencies

- `curl`: For making HTTP requests to GitHub API
- `jq`: For JSON parsing and cache management

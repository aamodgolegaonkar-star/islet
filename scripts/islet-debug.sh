#!/bin/bash
# Sends a debug command to a running Islet (requires:
#   defaults write local.islet.Islet debugTools -bool true   and a relaunch).
# Commands: capture | island.expand | island.collapse | player.open | player.close |
#           player.lyrics | settings.open | tutorial.open | tutorial.next | lock.preview | lock.fail | lock.expand | lock.lyrics | lock.collapse | lock.hide |
#           outputs | levels | island.charging | island.unlock | island.shelf | island.shelffiles | island.shelfclear | island.volume | island.brightness | island.airpods | island.max | island.sony | style.black | style.smokyGlass | style.clearGlass
set -euo pipefail
command="${1:?usage: islet-debug.sh <command>}"
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('local.islet.debug', '$command', \$(), true)" > /dev/null

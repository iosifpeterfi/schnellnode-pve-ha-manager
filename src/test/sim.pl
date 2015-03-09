#!/bin/sh

rm -rf simtest
mkdir simtest
perl -I .. ../pve-ha-simulator simtest

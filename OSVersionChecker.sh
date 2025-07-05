#!/bin/sh

sw_vers | awk '/ProductVersion/{print substr($2,1,5)}' | tr -d “.”
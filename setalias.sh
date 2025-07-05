#!/bin/bash

# Script to add alias ll='ls -alFh' to shell configuration

# Define the alias
ALIAS_LINE="alias ll='ls -alFh'"

# Check if ~/.bash_aliases exists, otherwise use ~/.bashrc
if [ -f "$HOME/.bash_aliases" ]; then
  TARGET_FILE="$HOME/.bash_aliases"
else
  TARGET_FILE="$HOME/.bashrc"
fi

# Check if the alias already exists in the target file
if grep -Fx "$ALIAS_LINE" "$TARGET_FILE" > /dev/null; then
  echo "Alias 'll' already exists in $TARGET_FILE"
else
  # Append the alias to the target file
  echo "$ALIAS_LINE" >> "$TARGET_FILE"
  echo "Added alias 'll' to $TARGET_FILE"
fi

# Source the target file to apply the alias in the current session
if [ -f "$TARGET_FILE" ]; then
  source "$TARGET_FILE"
  echo "Alias 'll' is now active in the current session"
else
  echo "Error: $TARGET_FILE not found"
  exit 1
fi

exit 0
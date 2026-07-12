#!/bin/bash

# The character you want to query (e.g., an emoji, a kanji, or plain text)
CHAR="${1:-🐈}"

# 1. Turn off echo and canonical mode so we can read the raw terminal response
stty -g > .stty_bak
stty -icanon -echo

# 2. Print the character, followed by the Device Status Report (DSR) escape sequence
# This asks the terminal: "Where is the cursor right now?"
printf "%s\e[6n" "$CHAR"

# 3. Read the terminal response (looks like \e[row;colR)
# We set a short timeout so it doesn't hang if run in an unsupported terminal
IFS=';' read -r -d 'R' -t 1 _ COL

# 4. Restore the terminal state immediately
stty "$(cat .stty_bak)"
rm -f .stty_bak

# 5. Calculate the column shift. Since columns are 1-indexed, 
# the width is simply (New Column - 1).
if [ -n "$COL" ]; then
    WIDTH=$((COL - 1))
    echo -e "\nCharacter: $CHAR"
    echo "Width in cells: $WIDTH"
else
    echo -e "\nError: Terminal did not respond to the width query."
fi

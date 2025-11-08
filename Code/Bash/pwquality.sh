#!/usr/bin/env sh
while : ; do
    # 24-32 random chars, mixed case, digits, symbols
    PASS=$(openssl rand -base64 32 | tr -d '/=' | head -c 24 ; echo)
    
    # Use pwscore to check quality. 
    # It reads the password from STDIN and sets exit code 0 if quality passes.
    echo "$PASS" | pwscore
    
    if [ $? -eq 0 ]; then
        echo "GOOD: $PASS"
        break
    else
        # Optional: Print score/error message for debugging if available
        # Some versions of pwscore print the score/error to STDERR
        : # loop continues
    fi
done
#!/usr/bin/env sh
while : ; do
    # 24-32 random chars, mixed case, digits, symbols
    PASS=$(openssl rand -base64 32 | tr -d '/=' | head -c 24 ; echo)
    echo "$PASS" | pwquality -s               # score it
    (( $? == 0 )) && echo "GOOD: $PASS" && break
done
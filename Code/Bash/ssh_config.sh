Host fipshost
    HostName        your.server
    KexAlgorithms   ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521
    Ciphers         aes128-gcm@openssh.com,aes256-gcm@openssh.com
    MACs            hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
    HostKeyAlgorithms ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256
    PubkeyAcceptedAlgorithms ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256
    # Optional: reject DSA, 1024-bit RSA
    CASignatureAlgorithms ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,rsa-sha2-512
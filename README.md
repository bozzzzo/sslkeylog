cloned from https://git.lekensteyn.nl/peter/wireshark-notes/ 

The repo contains loads of other stuff, but I needed only the sslkeylog for now

# sslkeylog

Dumps master keys for OpenSSL clients to file. The format is
documented at
https://developer.mozilla.org/en-US/docs/Mozilla/Projects/NSS/Key_Log_Format

* Capture the traffic with wireshark, 
* right click on a TLS packet line 
* select `Protocol Preferences...` -> `(Pre)-Master-Secret log filename...` and 
* enter the full path to the `premaster.txt`

## Building

### Linux

        cc sslkeylog.c -shared -o libsslkeylog.so -fPIC -ldl

### OSX

        cc sslkeylog.c -dynamiclib -o libsslkeylog.dylib -I$(brew --prefix openssl)/include -L$(brew --prefix openssl)/lib -lssl

## Usage

### Linux

        SSLKEYLOGFILE=premaster.txt LD_PRELOAD=./libsslkeylog.so openssl ...

### OSX

        SSLKEYLOGFILE=premaster.txt DYLD_FORCE_FLAT_NAMESPACE=1 DYLD_INSERT_LIBRARIES=./libsslkeylog.dylib openssl ...

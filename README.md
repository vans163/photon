# photon
Extremely Flexible Web(server)library

![image](https://user-images.githubusercontent.com/3028982/171968539-2af1b7f0-fc22-44ae-aace-c8995c76cf5f.png)

## Why?

After using https://github.com/vans163/stargate for years and years, I realize webservers need to be flexible. 
I constantly found myself patching stargate little by little because each project needed a slightly different feature,
like chunk streaming request, then chunk streaming response, then multiplexing different services on the same socket,
then customizing how websocket paths are mapped, then more. Building a monolith type architecture that stargate was and 
constantly piling on features is not the way to go.

## How then?

`photon` ships as a library with the building blocks required to build web services, it will or includes:

 - [ ] HTTP Request and Response builder/parser
 - [ ] Websockets frame builder/parser with permessage deflate
 - [ ] Steppable functions to parse incoming requests
 - [ ] Path and other sanitization
 - [ ] GZIP, Cors and other helpers


## What is it not

A webserver. You cannot run it like a monolith genserver. You need to provide the supervision and socket handling yourself.

defmodule Photon.GenTCP do
    def listen(port, opts \\ []) do
        {:ok, lsocket} = :gen_tcp.listen(port, opts)
        #IPPROTO_TCP 6
        #TCP_QUICKACK 12
        :inet.setopts(lsocket, [{:raw, 6, 12, <<1::32-native>>}])

        #TODO: why it broken, just use QUIC
        #IO.inspect {:fast_open, :inet.getopts(lsocket, [{:raw, 6, 23, 4}])}
        #IO.inspect :inet.setopts(lsocket, [{:raw, 6, 23, <<16384::32-native>>}])
        #IO.inspect {:fast_open, :inet.getopts(lsocket, [{:raw, 6, 23, 4}])}
        #:inet.getopts(clientSocket, [{:raw, 0, 80, 16}])
        #SOL_TCP 6
        #TCP_FASTOPEN 23
        #setsockopt(fd, SOL_TCP, TCP_FASTOPEN, &qlen, sizeof(qlen));
        #{raw, Protocol, OptionNum, ValueBin}

        lsocket
    end

    def listen_highthruput(port, opts \\ []) do
        buffer = 8388608
        basic_opts = [
            {:inet_backend, :socket},
            {:nodelay, true},
            {:active, false},
            {:reuseaddr, true},
            {:exit_on_close, false},
            :binary,
            {:buffer, buffer},
            {:backlog, 16384}
        ]
        listen(port, basic_opts++opts)
    end

    def connect(ip, port, opts \\ [], transport \\ :gen_tcp) do
        buffer = 131072
        basic_opts = [
            #{:inet_backend, :socket}, #not supported for SSL? :()
            {:nodelay, true},
            {:active, false},
            {:reuseaddr, true},
            {:exit_on_close, false},
            :binary,
            {:buffer, buffer},
        ]
        {:ok, socket} = transport.connect(ip, port, basic_opts++opts, 8_000)
        #TCP_QUICKACK
        if transport == :gen_tcp do
            :inet.setopts(socket, [{:raw, 6, 12, <<1::32-native>>}])
        else
            :ssl.setopts(socket, [{:raw, 6, 12, <<1::32-native>>}])
        end
        socket
    end

    def connect_url(url, opts \\ []) do
        uri = URI.parse(url)
        port = cond do uri.port -> uri.port; uri.scheme in ["http","ws"] -> 80; uri.scheme in ["https","wss"] -> 443 end
        {host_parse_err, host_parsed} = :inet.parse_ipv4_address('#{uri.host}')
        {host_parse_err, host_parsed} = if host_parse_err == :ok do {host_parse_err, host_parsed} else
            :inet.parse_ipv6_address('#{uri.host}')
        end
        cond do
            uri.scheme in ["https", "wss"] ->
                ssl_opts = [
                    {:server_name_indication, '#{uri.host}'},
                    {:verify,:verify_peer},
                    {:depth,99},
                    {:cacerts, :certifi.cacerts()},
                    #{:verify_fun, verifyFun},
                    {:partial_chain, &Photon.SSLPin.partial_chain/1},
                    {:customize_hostname_check, [{:match_fun, :public_key.pkix_verify_hostname_match_fun(:https)}]}
                ]
                connect('#{uri.host}', port, ssl_opts++opts, :ssl)
            host_parse_err == :ok -> connect(host_parsed, port, opts)
            true -> connect('#{uri.host}', port, opts)
        end
    end

    #Misc
    def setopts(socket={:sslsocket, _, _}, opts) do
        :ssl.setopts(socket, opts)
    end
    def setopts(socket, opts) do
        :inet.setopts(socket, opts)
    end

    def send(socket={:sslsocket, _, _}, bin) do
        :ssl.send(socket, bin)
    end
    def send(socket, bin) do
        :gen_tcp.send(socket, bin)
    end

    def recv(socket, to_recv \\ 0, timeout \\ :infinity)
    def recv(socket={:sslsocket, _, _}, to_recv, timeout) do
        {:ok, bin} = :ssl.recv(socket, to_recv, timeout)
        bin
    end
    def recv(socket, to_recv, timeout) do
        {:ok, bin} = :gen_tcp.recv(socket, to_recv, timeout)
        bin
    end
end

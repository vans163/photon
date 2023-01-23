defmodule Photon.GenTCP do
    def listen(port, opts \\ []) do
        {:ok, lsocket} = :gen_tcp.listen(port, opts)

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

    def connect(ip, port, opts \\ [], transport \\ :gen_tcp, timeout \\ 8_000) do
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
        {:ok, socket} = transport.connect(ip, port, basic_opts++opts, timeout)
        socket
    end

    def connect_url(url, opts \\ []) do
        uri = URI.parse(url)
        port = cond do uri.port -> uri.port; uri.scheme in ["http","ws"] -> 80; uri.scheme in ["https","wss"] -> 443 end
        if uri.scheme in ["https", "wss"] do
            ssl_opts = [
                {:server_name_indication, '#{URI.parse(url).host}'},
                {:verify,:verify_peer},
                {:depth,99},
                {:cacerts, :certifi.cacerts()},
                #{:verify_fun, verifyFun},
                {:partial_chain, &Photon.SSLPin.partial_chain/1},
                {:customize_hostname_check, [{:match_fun, :public_key.pkix_verify_hostname_match_fun(:https)}]}
            ]
            connect('#{uri.host}', port, ssl_opts++opts, :ssl)
        else
            connect('#{uri.host}', port, opts)
        end
    end

    #Misc
    def setopts(socket, opts) when is_port(socket) do
        :inet.setopts(socket, opts)
    end
    def setopts(socket, opts) when is_tuple(socket) do
        :ssl.setopts(socket, opts)
    end

    def send(socket, bin) when is_port(socket) do
        :gen_tcp.send(socket, bin)
    end
    def send(socket, bin) when is_tuple(socket) do
        :ssl.send(socket, bin)
    end
end
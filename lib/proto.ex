defmodule Photon.Proto do
    def peek({:'$inet', :gen_tcp_socket, {_pid, socket}}) do
        {:ok, bin} = :socket.recv(socket, 0, [:peek], 6000)
        {peek_all(bin), bin}
    end

    def peek_all(<<"HEA", _::binary>>), do: :http
    def peek_all(<<"OPT", _::binary>>), do: :http
    def peek_all(<<"GET", _::binary>>), do: :http
    def peek_all(<<"POS", _::binary>>), do: :http
    def peek_all(<<"PUT", _::binary>>), do: :http
    def peek_all(<<"DEL", _::binary>>), do: :http
    def peek_all(<<"PAT", _::binary>>), do: :http
    def peek_all(<<0x16,0x03,0x00,_::binary>>), do: :ssl
    def peek_all(<<0x16,0x03,0x01,_::binary>>), do: :ssl
    def peek_all(<<0x16,0x03,0x02,_::binary>>), do: :ssl
    def peek_all(<<0x16,0x03,0x03,_::binary>>), do: :ssl
    def peek_all(<<0x16,0x03,0x04,_::binary>>), do: :ssl
    def peek_all(<<0x16,0x03,0x05,_::binary>>), do: :ssl
    def peek_all(<<5,1,0,_::binary>>), do: :socks5
    def peek_all(_), do: :raw

    def peek_http(<<"HEA", _::binary>>), do: true
    def peek_http(<<"OPT", _::binary>>), do: true
    def peek_http(<<"GET", _::binary>>), do: true
    def peek_http(<<"POS", _::binary>>), do: true
    def peek_http(<<"PUT", _::binary>>), do: true
    def peek_http(<<"DEL", _::binary>>), do: true
    def peek_http(<<"PAT", _::binary>>), do: true
    def peek_http(_), do: false

    def peek_ssl(<<0x16,3,_::binary>>), do: false
    def peek_ssl(_), do: false

    def peek_socks5(<<5,1,0,_::binary>>), do: true
    def peek_socks5(_), do: false
end
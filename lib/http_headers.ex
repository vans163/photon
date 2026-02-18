defmodule Photon.HTTP.Headers do
    def parse(state) do
        case :binary.split(state.buf, "\r\n\r\n") do
            [headers, buf] ->
                headers = String.split(headers, "\r\n")
                headers_list = Enum.map(headers, fn(line)->
                    [k,v] = :binary.split(line, ": ")
                    k = String.downcase(k)
                    v = case {k,v} do
                        {"connection", "Keep-Alive"} -> "keep-alive"
                        {"connection", "Close"} -> "close"
                        {"connection", "Upgrade"} -> "upgrade"
                        {_k,v} -> v
                    end
                    %{key: k, value: v}
                end)
                headers = Enum.into(headers_list, %{}, & {&1.key, &1.value})
                Map.merge(state, %{headers: headers, headers_list: headers_list, buf: buf, step: :body})
            _ -> {:partial, state}
        end
    end

    def build(headers \\ %{}) do
        Enum.reduce(headers, "", & &2 <> "#{elem(&1,0)}: #{elem(&1,1)}\r\n")
        |> String.trim()
    end

    def build_date() do
        dt = DateTime.utc_now()
        day_of_week = Calendar.ISO.day_of_week(dt.year, dt.month, dt.day)
        day_of_week = case day_of_week do
            1 -> "Mon"
            2 -> "Tue"
            3 -> "Wed"
            4 -> "Thu"
            5 -> "Fri"
            6 -> "Sat"
            7 -> "Sun"
        end
        month = case dt.month do
            1 -> "Jan"
            2 -> "Feb"
            3 -> "Mar"
            4 -> "Apr"
            5 -> "May"
            6 -> "Jun"
            7 -> "Jul"
            8 -> "Aug"
            9 -> "Sep"
            10 -> "Oct"
            11 -> "Nov"
            12 -> "Dec"
        end
        "#{day_of_week}, #{dt.day} #{month} #{dt.year} #{dt.hour}:#{dt.minute}:#{dt.second} GMT"
    end

    def add_cors(headers) do
        Map.merge(headers, %{
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "HEAD, OPTIONS, PATH, GET, POST, PUT, DELETE",
            "Access-Control-Allow-Headers" => "User-Agent, Cache-Control, Pragma, Origin, Authorization, Content-Type, X-Auth-Token, X-Client-Type, X-Requested-With, Location, Extra, Filename, If-Modified-Since, DNT, Accept",
        })
    end

    def add_date(headers) do
        Map.merge(headers, %{
            "Date"=> build_date(),
        })
    end

    def add_content_length(headers, body) do
        Map.merge(headers, %{
            "Content-Length"=> "#{byte_size(body)}",
        })
    end

    def add_connection(headers, request) do
        Map.merge(headers, %{
            "Connection"=> (if request.headers["connection"] == "close" do "close" else "keep-alive" end),
        })
    end

    def can_accept_gzip(headers) do
        Map.get(headers, "accept-encoding", "")
        |> :binary.match("gzip")
        |> case do
            :nomatch -> false
            _ -> true
        end
    end

    def is_cached(headers, etag) do
        cache_etag = headers["if-none-match"]
        cache_etag == etag
    end
end

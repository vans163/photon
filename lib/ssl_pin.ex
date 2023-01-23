defmodule Photon.SSLPin do
    def partial_chain(certs) do
        certs = :lists.reverse(Enum.map(certs, fn(cert)-> {cert, :public_key.pkix_decode_cert(cert, :otp)} end))
        case find(fn({_,cert})-> check_cert(decoded_cacerts(), cert) end, certs) do
            {:ok, trusted} -> {:trusted_ca, :erlang.element(1, trusted)}
            _ -> :unknown_ca
        end
    end
    defp find(fun, [h|t]) when is_function(fun) do
        case fun.(h) do
            true -> {:ok, h}
            false -> find(fun, t)
        end
    end
    defp find(_,[]), do: :error
    defp check_cert(caCerts, cert) do
        publicKeyInfo = :hackney_ssl_certificate.public_key_info(cert)
        :lists.member(publicKeyInfo, caCerts)
    end
    defp decoded_cacerts() do
        :ct_expand.term(
            :lists.foldl(fn(cert, acc) ->
                    dec = :public_key.pkix_decode_cert(cert, :otp)
                    [:hackney_ssl_certificate.public_key_info(dec) | acc]
                end, [], :certifi.cacerts())
        )
    end
end
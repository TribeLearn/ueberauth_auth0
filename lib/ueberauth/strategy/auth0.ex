defmodule Ueberauth.Strategy.Auth0 do
  @moduledoc """
  Provides an Ueberauth strategy for authenticating with Auth0.

  You can edit the behaviour of the Strategy by including some options when you register your provider.

  To set the `uid_field`
      config :ueberauth, Ueberauth,
        providers: [
          auth0: { Ueberauth.Strategy.Auth0, [uid_field: :email] }
        ]
  Default is `:user_id`

  To set the default ['scopes'](https://auth0.com/docs/scopes) (permissions):
      config :ueberauth, Ueberauth,
        providers: [
          auth0: { Ueberauth.Strategy.Auth0, [default_scope: "openid email"] }
        ]
  Deafult is "openid email"
  """
  use Ueberauth.Strategy, uid_field: :user_id,
                          default_scope: "openid email",
                          oauth2_module: Ueberauth.Strategy.Auth0.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials

  @doc """
  Handles the initial redirect to the Auth0 authentication page.
  You can include a `state` param that Auth0 will return to you.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)
    opts = [scope: scopes]

    opts =
      if conn.params["state"], do: Keyword.put(opts, :state, conn.params["state"]), else: opts

    opts = Keyword.put(opts, :redirect_uri, callback_url(conn))
    module = option(conn, :oauth2_module)

    redirect!(conn, apply(module, :authorize_url!, [opts]))
  end

  @doc """
  Handles the callback from Auth0. When there is a failure from Auth0 the failure is included in the
  `ueberauth_failure` struct. Otherwise the information returned from Auth0 is returned in the `Ueberauth.Auth` struct.
  """
  def handle_callback!(%Plug.Conn{ params: %{ "code" => code } } = conn) do
    module = option(conn, :oauth2_module)
    redirect_uri = callback_url(conn)
    client = apply(module, :get_token!, [[code: code, redirect_uri: redirect_uri]])
    token = client.token
    if token.access_token == nil do
      set_errors!(conn, [error(token.other_params["error"], token.other_params["error_description"])])
    else
      fetch_user(conn, client)
    end
  end

  @doc false
  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up the private area of the connection used for passing the raw Auth0 response around during the callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:auth0_user, nil)
    |> put_private(:auth0_token, nil)
  end

  defp fetch_user(conn, client = %{token: token}) do
    conn = put_private(conn, :auth0_token, token)
    case OAuth2.Client.get(client, "/userinfo") do
      { :ok, %OAuth2.Response{status_code: 401, body: _body}} ->
        set_errors!(conn, [error("token", "unauthorized")])
      { :ok, %OAuth2.Response{status_code: status_code, body: user} } when status_code in 200..399 ->
        put_private(conn, :auth0_user, user)
      { :error, %OAuth2.Error{reason: reason} } ->
        set_errors!(conn, [error("OAuth2", reason)])
    end
  end

  @doc """
  Fetches the uid field from the Auth0 response.
  """
  def uid(conn) do
    conn.private.auth0_user[option(conn, :uid_field) |> to_string]
  end

  @doc """
  Includes the credentials from the Auth0 response.
  """
  def credentials(conn) do
    token = conn.private.auth0_token
    scopes = (token.other_params["scope"] || "")
    |> String.split(",")

    %Credentials{
      token: token.access_token,
      refresh_token: token.refresh_token,
      token_type: token.token_type,
      expires_at: token.expires_at,
      expires: !!token.expires_at,
      scopes: scopes,
      other: token.other_params
    }
  end

  @doc """
  Fetches the fields to populate the info section of the `Ueberauth.Auth` struct.
  """
  def info(conn) do
    user = conn.private.auth0_user

    %Info{
      name: user["name"],
      nickname: user["nickname"],
      email: user["email"],
      location: user["locale"],
      first_name: user["given_name"],
      last_name: user["family_name"],
      image: user["picture"]
    }
  end

  defp option(conn, key) do
    Dict.get(options(conn), key, Dict.get(default_options, key))
  end
end

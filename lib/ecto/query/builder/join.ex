import Kernel, except: [apply: 2]

defmodule Ecto.Query.Builder.Join do
  @moduledoc false

  alias Ecto.Query.Builder
  alias Ecto.Query.JoinExpr

  @doc """
  Escapes a join expression (not including the `on` expression).

  It returns a tuple containing the binds, the on expression (if available)
  and the association expression.

  ## Examples

      iex> escape(quote(do: x in "foo"), [], __ENV__)
      {:x, {"foo", nil}, nil, %{}}

      iex> escape(quote(do: "foo"), [], __ENV__)
      {:_, {"foo", nil}, nil, %{}}

      iex> escape(quote(do: x in Sample), [], __ENV__)
      {:x, {nil, {:__aliases__, [alias: false], [:Sample]}}, nil, %{}}

      iex> escape(quote(do: x in {"foo", Sample}), [], __ENV__)
      {:x, {"foo", {:__aliases__, [alias: false], [:Sample]}}, nil, %{}}

      iex> escape(quote(do: x in {"foo", :sample}), [], __ENV__)
      {:x, {"foo", :sample}, nil, %{}}

      iex> escape(quote(do: c in assoc(p, :comments)), [p: 0], __ENV__)
      {:c, nil, {0, :comments}, %{}}

      iex> escape(quote(do: x in fragment("foo")), [], __ENV__)
      {:x, {:{}, [], [:fragment, [], [raw: "foo"]]}, nil, %{}}

  """
  @spec escape(Macro.t, Keyword.t, Macro.Env.t) :: {[atom], Macro.t | nil, Macro.t | nil, %{}}
  def escape({:in, _, [{var, _, context}, expr]}, vars, env)
      when is_atom(var) and is_atom(context) do
    {_, expr, assoc, params} = escape(expr, vars, env)
    {var, expr, assoc, params}
  end

  def escape({:subquery, _, [expr]}, _vars, _env) do
    {:_, quote(do: Ecto.Query.subquery(unquote(expr))), nil, %{}}
  end

  def escape({:fragment, _, [_|_]} = expr, vars, env) do
    {expr, params} = Builder.escape(expr, :any, %{}, vars, env)
    {:_, expr, nil, params}
  end

  def escape({:__aliases__, _, _} = module, _vars, _env) do
    {:_, {nil, module}, nil, %{}}
  end

  def escape(string, _vars, _env) when is_binary(string) do
    {:_, {string, nil}, nil, %{}}
  end

  def escape({string, {:__aliases__, _, _} = module}, _vars, _env) when is_binary(string) do
    {:_, {string, module}, nil, %{}}
  end

  def escape({string, atom}, _vars, _env) when is_binary(string) and is_atom(atom) do
    {:_, {string, atom}, nil, %{}}
  end

  def escape({:assoc, _, [{var, _, context}, field]}, vars, _env)
      when is_atom(var) and is_atom(context) do
    ensure_field!(field)
    var   = Builder.find_var!(var, vars)
    field = Builder.quoted_field!(field)
    {:_, nil, {var, field}, %{}}
  end

  def escape({:^, _, [expr]}, _vars, _env) do
    {:_, quote(do: Ecto.Query.Builder.Join.join!(unquote(expr))), nil, %{}}
  end

  def escape(join, vars, env) do
    case Macro.expand(join, env) do
      ^join ->
        Builder.error! "malformed join `#{Macro.to_string(join)}` in query expression"
      join ->
        escape(join, vars, env)
    end
  end

  @doc """
  Called at runtime to check dynamic joins.
  """
  def join!(expr) when is_atom(expr),
    do: {nil, expr}
  def join!(expr) when is_binary(expr),
    do: {expr, nil}
  def join!({source, module}) when is_binary(source) and is_atom(module),
    do: {source, module}
  def join!(expr),
    do: Ecto.Queryable.to_query(expr)

  @doc """
  Builds a quoted expression.

  The quoted expression should evaluate to a query at runtime.
  If possible, it does all calculations at compile time to avoid
  runtime work.
  """
  @spec build(Macro.t, atom, [Macro.t], Macro.t, Macro.t, Macro.t, Macro.Env.t) ::
              {Macro.t, Keyword.t, non_neg_integer | nil}
  def build(query, qual, binding, expr, on, count_bind, env) do
    {query, binding} = Builder.escape_binding(query, binding)
    {join_bind, join_expr, join_assoc, join_params} = escape(expr, binding, env)
    join_params = Builder.escape_params(join_params)

    qual = validate_qual(qual)
    validate_bind(join_bind, binding)

    {count_bind, query} =
      if join_bind != :_ and !count_bind do
        # If count_bind is not available,
        # we need to compute the amount of binds at runtime
        query =
          quote do
            query = Ecto.Queryable.to_query(unquote(query))
            join_count = Builder.count_binds(query)
            query
          end
        {quote(do: join_count), query}
      else
        {count_bind, query}
      end

    binding = binding ++ [{join_bind, count_bind}]
    join_on = escape_on(on || true, binding, env)

    join =
      quote do
        %JoinExpr{qual: unquote(qual), source: unquote(join_expr),
                  on: unquote(join_on), assoc: unquote(join_assoc),
                  file: unquote(env.file), line: unquote(env.line),
                  params: unquote(join_params)}
      end

    query = Builder.apply_query(query, __MODULE__, [join], env)

    next_bind =
      if is_integer(count_bind) do
        count_bind + 1
      else
        quote(do: unquote(count_bind) + 1)
      end

    {query, binding, next_bind}
  end

  def apply(%Ecto.Query{joins: joins} = query, expr) do
    %{query | joins: joins ++ [expr]}
  end
  def apply(query, expr) do
    apply(Ecto.Queryable.to_query(query), expr)
  end

  defp escape_on(on, binding, env) do
    {on, params} = Builder.escape(on, :boolean, %{}, binding, env)
    params       = Builder.escape_params(params)

    quote do: %Ecto.Query.QueryExpr{
                expr: unquote(on),
                params: unquote(params),
                line: unquote(env.line),
                file: unquote(env.file)}
  end

  defp validate_qual(qual) when is_atom(qual) do
    qual!(qual)
  end

  defp validate_qual(qual) do
    quote(do: Ecto.Query.Builder.Join.qual!(unquote(qual)))
  end

  defp validate_bind(bind, all) do
    if bind != :_ and bind in all do
      Builder.error! "variable `#{bind}` is already defined in query"
    end
  end

  @qualifiers [:inner, :inner_lateral, :left, :left_lateral, :right, :full]

  @doc """
  Called at runtime to check dynamic qualifier.
  """
  def qual!(qual) when qual in @qualifiers, do: qual
  def qual!(qual) do
    raise ArgumentError,
      "invalid join qualifier `#{inspect qual}`, accepted qualifiers are: " <>
      Enum.map_join(@qualifiers, ", ", &"`#{inspect &1}`")
  end

  defp ensure_field!({var, _, _}) when var != :^ do
    Builder.error! "you passed the variable `#{var}` to `assoc/2`. Did you mean to pass the atom `:#{var}?`"
  end
  defp ensure_field!(_), do: true
end

defmodule Nx.Util do
  @moduledoc """
  A collection of helper functions for working with tensors.

  Generally speaking, the usage of these functions is discouraged,
  as they don't work inside `defn` and the `Nx` module often has
  higher-level features around them.
  """

  alias Nx.Tensor, as: T
  import Nx.Shared

  @doc """
  Returns the underlying tensor as a bitstring.

  The bitstring is returned as is (which is row-major).
  """
  def to_bitstring(%T{data: {Nx.BitStringDevice, data}}), do: data

  def to_bitstring(%T{data: {device, _data}}) do
    raise ArgumentError,
          "cannot read Nx.Tensor data because the data is allocated on device #{inspect(device)}. " <>
            "Please use Nx.device_transfer/1 to transfer data back to Elixir"
  end

  @doc """
  Creates a one-dimensional tensor from a `bitstring` with the given `type`.

  If the bitstring size does not match its type, an error is raised.

  ## Examples

      iex> Nx.Util.from_bitstring(<<1, 2, 3, 4>>, {:s, 8})
      #Nx.Tensor<
        s8[4]
        [1, 2, 3, 4]
      >

      iex> Nx.Util.from_bitstring(<<12.3::float-64-native>>, {:f, 64})
      #Nx.Tensor<
        f64[1]
        [12.3]
      >

      iex> Nx.Util.from_bitstring(<<1, 2, 3, 4>>, {:f, 64})
      ** (ArgumentError) bitstring does not match the given size

  """
  def from_bitstring(bitstring, type) when is_bitstring(bitstring) do
    {_, size} = Nx.Type.validate!(type)
    dim = div(bit_size(bitstring), size)

    if bitstring == "" do
      raise ArgumentError, "cannot build an empty tensor"
    end

    if rem(bit_size(bitstring), size) != 0 do
      raise ArgumentError, "bitstring does not match the given size"
    end

    %T{data: {Nx.BitStringDevice, bitstring}, type: type, shape: {dim}}
  end

  @doc """
  Reduces over a tensor with the given accumulator.

  The tensor may be reduced in parallel. The evaluation
  order of the reduction function is arbitrary and may
  be non-deterministic. Therefore, the reduction function
  should not be overly sensitive to reassociation.

  If the `:axis` option is given, it aggregates over
  that dimension, effectively removing it. `axis: 0`
  implies aggregating over the highest order dimension
  and so forth. If the axis is negative, then counts
  the axis from the back. For example, `axis: -1` will
  always aggregate all rows.

  ## Examples

      iex> Nx.Util.reduce(Nx.tensor(42), 0, &+/2)
      #Nx.Tensor<
        s64
        42
      >

      iex> Nx.Util.reduce(Nx.tensor([1, 2, 3]), 0, &+/2)
      #Nx.Tensor<
        s64
        6
      >

      iex> Nx.Util.reduce(Nx.tensor([[1.0, 2.0], [3.0, 4.0]]), 0, &+/2)
      #Nx.Tensor<
        f64
        10.0
      >

  ### Aggregating over an axis

      iex> t = Nx.tensor([1, 2, 3])
      iex> Nx.Util.reduce(t, 0, [axis: 0], &+/2)
      #Nx.Tensor<
        s64
        6
      >

      iex> t = Nx.tensor([[[1, 2, 3], [4, 5, 6]], [[7, 8, 9], [10, 11, 12]]])
      iex> Nx.Util.reduce(t, 0, [axis: 0], &+/2)
      #Nx.Tensor<
        s64[2][3]
        [
          [8, 10, 12],
          [14, 16, 18]
        ]
      >

      iex> t = Nx.tensor([[[1, 2, 3], [4, 5, 6]], [[7, 8, 9], [10, 11, 12]]])
      iex> Nx.Util.reduce(t, 0, [axis: 1], &+/2)
      #Nx.Tensor<
        s64[2][3]
        [
          [5, 7, 9],
          [17, 19, 21]
        ]
      >

      iex> t = Nx.tensor([[[1, 2, 3], [4, 5, 6]], [[7, 8, 9], [10, 11, 12]]])
      iex> Nx.Util.reduce(t, 0, [axis: 2], &+/2)
      #Nx.Tensor<
        s64[2][2]
        [
          [6, 15],
          [24, 33]
        ]
      >

      iex> t = Nx.tensor([[[1, 2, 3], [4, 5, 6]], [[7, 8, 9], [10, 11, 12]]])
      iex> Nx.Util.reduce(t, 0, [axis: -1], &+/2)
      #Nx.Tensor<
        s64[2][2]
        [
          [6, 15],
          [24, 33]
        ]
      >

      iex> t = Nx.tensor([[[1, 2, 3], [4, 5, 6]], [[7, 8, 9], [10, 11, 12]]])
      iex> Nx.Util.reduce(t, 0, [axis: -3], &+/2)
      #Nx.Tensor<
        s64[2][3]
        [
          [8, 10, 12],
          [14, 16, 18]
        ]
      >

  ### Errors

      iex> Nx.Util.reduce(Nx.tensor([1, 2, 3]), 0, [axis: 1], &+/2)
      ** (ArgumentError) unknown axis 1 for shape {3} (axis is zero-indexed)

  """
  def reduce(tensor, acc, opts \\ [], fun)

  def reduce(number, acc, opts, fun) when is_number(number) do
    reduce(Nx.tensor(number), acc, opts, fun)
  end

  def reduce(%T{type: {_, size} = type, shape: shape} = t, acc, opts, fun)
      when is_list(opts) and is_function(fun, 2) do
    data = to_bitstring(t)

    {data, shape} =
      if axis = opts[:axis] do
        {gap_count, chunk_count, new_shape} = aggregate_axis(shape, axis)
        chunk_size = chunk_count * size

        new_data =
          for <<chunk::size(chunk_size)-bitstring <- data>> do
            aggregate_gaps(gap_count, size, fn pre, pos ->
              match_types [type] do
                value =
                  for <<_::size(pre)-bitstring, match!(var, 0), _::size(pos)-bitstring <- chunk>>,
                    reduce: acc,
                    do: (acc -> fun.(read!(var, 0), acc))

                <<write!(value, 0)>>
              end
            end)
          end

        {new_data, new_shape}
      else
        new_data =
          match_types [type] do
            value =
              for <<match!(var, 0) <- data>>,
                reduce: acc,
                do: (acc -> fun.(read!(var, 0), acc))

            <<write!(value, 0)>>
          end

        {new_data, {}}
      end

    %{t | data: {Nx.BitStringDevice, IO.iodata_to_binary(data)}, shape: shape}
  end

  ## Dimension helpers

  # The goal of aggregate axis is to find a chunk_count and gap_count
  # that allows us to traverse the tensor. Consider this input tensor:
  #
  #     #Nx.Tensor<
  #       s64[2][2][3]
  #       [
  #         [
  #           [1, 2, 3],
  #           [4, 5, 6]
  #         ],
  #         [
  #           [7, 8, 9],
  #           [10, 11, 12]
  #         ]
  #       ]
  #     >
  #
  # When computing the sum on axis 0, we have:
  #
  #     #Nx.Tensor<
  #       s64[2][3]
  #       [
  #         [8, 10, 12],
  #         [14, 16, 18]
  #       ]
  #     >
  #
  # The first time element is 1 + 7, which means the gap between
  # them is 6. Given we have to traverse the whole tensor, the
  # chunk_count is 12 (the size of the tensor).
  #
  # For axis 1, we have:
  #
  #     #Nx.Tensor<
  #       s64[2][3]
  #       [
  #         [5, 7, 9],
  #         [17, 19, 21]
  #       ]
  #     >
  #
  # The first element is 1 + 4 within the "first quadrant". 17 is
  # is 10 + 17 in the second quadrant. Therefore the gap is 3 and
  # the chunk_count is 6 elements.
  #
  # Finally, for axis 2, we have:
  #
  #     #Nx.Tensor<
  #       s64[2][2]
  #       [
  #         [6, 15],
  #         [24, 33]
  #       ]
  #     >
  #
  # 6 is the sum of the first row, 15 the sum of the second row, etc.
  # Therefore the gap is 1 and the chunk size is 3.
  #
  # Computing the aggregate is a matter of mapping the binary over
  # each chunk and then mapping gap times, moving the computation root
  # by size over each gap.
  defp aggregate_axis(shape, axis) when axis >= 0 and axis < tuple_size(shape) do
    total = tuple_product(shape)
    aggregate_axis(Tuple.to_list(shape), 0, axis, total, total, [])
  end

  defp aggregate_axis(shape, axis) when axis < 0 and axis >= -tuple_size(shape) do
    total = tuple_product(shape)
    aggregate_axis(Tuple.to_list(shape), 0, tuple_size(shape) + axis, total, total, [])
  end

  defp aggregate_axis(shape, axis) do
    raise ArgumentError, "unknown axis #{axis} for shape #{inspect(shape)} (axis is zero-indexed)"
  end

  defp aggregate_axis([dim | dims], axis, chosen, chunk, gap, acc) do
    gap = div(gap, dim)

    if axis == chosen do
      {gap, chunk, List.to_tuple(Enum.reverse(acc, dims))}
    else
      aggregate_axis(dims, axis + 1, chosen, div(chunk, dim), gap, [dim | acc])
    end
  end

  defp aggregate_gaps(gap_count, size, fun),
    do: aggregate_gaps(0, gap_count * size, size, fun)

  defp aggregate_gaps(_pre, 0, _size, _fun),
    do: []

  defp aggregate_gaps(pre, pos, size, fun),
    do: [fun.(pre, pos - size) | aggregate_gaps(pre + size, pos - size, size, fun)]
end
export find_representative_periods, split_into_periods!

"""
    combine_periods!(df)

Modifies a dataframe `df` by combining the columns `timestep` and `period`
into a single column `timestep` of global time steps. The period duration is
inferred automatically from the maximum time step value, assuming that
periods start with time step 1.

# Examples

```
julia> df = DataFrame([:period => [1, 1, 2], :timestep => [1, 2, 1], :value => 1:3])
3×3 DataFrame
 Row │ period  timestep  value
     │ Int64   Int64      Int64
─────┼──────────────────────────
   1 │      1          1      1
   2 │      1          2      2
   3 │      2          1      3

julia> TulipaClustering.combine_periods!(df)
3×2 DataFrame
 Row │ timestep  value
     │ Int64      Int64
─────┼──────────────────
   1 │         1      1
   2 │         2      2
   3 │         3      3
```
"""
function combine_periods!(df::AbstractDataFrame)
  # First check that df contains a timestep column
  if columnindex(df, :timestep) == 0
    throw(DomainError(df, "DataFrame does not contain a column `timestep`"))
  end
  if columnindex(df, :period) == 0
    return  # if there is no column df.period, leave df as is
  end
  max_t = maximum(df.timestep)
  df.timestep .= (df.period .- 1) .* max_t .+ df.timestep
  select!(df, Not(:period))
end

"""
    split_into_periods!(df; period_duration=nothing)

Modifies a dataframe `df` by separating the column `timestep` into periods of
length `period_duration`. The new data is written into two columns:

  - `period`: the period ID;
  - `timestep`: the time step within the current period.

If `period_duration` is `nothing`, then all of the time steps are within the
same period with index 1.

# Examples

```
julia> df = DataFrame([:timestep => 1:4, :value => 5:8])
4×2 DataFrame
 Row │ timestep  value
     │ Int64      Int64
─────┼──────────────────
   1 │         1      5
   2 │         2      6
   3 │         3      7
   4 │         4      8

julia> TulipaClustering.split_into_periods!(df; period_duration=2)
4×3 DataFrame
 Row │ period  timestep  value
     │ Int64   Int64      Int64
─────┼──────────────────────────
   1 │      1          1      5
   2 │      1          2      6
   3 │      2          1      7
   4 │      2          2      8

julia> df = DataFrame([:period => [1, 1, 2], :timestep => [1, 2, 1], :value => 1:3])
3×3 DataFrame
 Row │ period  timestep  value
     │ Int64   Int64      Int64
─────┼──────────────────────────
   1 │      1          1      1
   2 │      1          2      2
   3 │      2          1      3

julia> TulipaClustering.split_into_periods!(df; period_duration=1)
3×3 DataFrame
 Row │ period  timestep  value
     │ Int64   Int64      Int64
─────┼──────────────────────────
   1 │      1          1      1
   2 │      2          1      2
   3 │      3          1      3

julia> TulipaClustering.split_into_periods!(df)
3×3 DataFrame
 Row │ period  timestep  value
     │ Int64   Int64      Int64
─────┼──────────────────────────
   1 │      1          1      1
   2 │      1          2      2
   3 │      1          3      3
```
"""
function split_into_periods!(df::AbstractDataFrame; period_duration::Union{Int, Nothing} = nothing)
  # If the periods already exist, combine them into the time steps if necessary
  combine_periods!(df)

  if isnothing(period_duration)
    # If period_duration is nothing, then leave the time steps as is and
    # everything is just the same period with index 1.
    insertcols!(df, :period => 1)
  else
    # Otherwise, split the time step index using 1-based modular arithmetic
    indices = fldmod1.(df.timestep, period_duration)  # find the new indices
    indices = reinterpret(reshape, Int, indices)       # change to an array for slicing

    df.period = indices[1, :]     # first row is the floor quotients, i.e., the period indices
    df.timestep = indices[2, :]  # second row is the remainders, i.e., the new time steps
  end
  select!(df, :period, :timestep, :)  # move the time-related columns to the front
end

"""
    validate_df_and_find_key_columns(df)

Checks that dataframe `df` contains the necessary columns and returns a list of
columns that act as keys (i.e., unique data identifiers within different periods).

# Examples

```
julia> df = DataFrame([:period => [1, 1, 2], :timestep => [1, 2, 1], :a .=> "a", :value => 1:3])
3×4 DataFrame
 Row │ period  timestep  a       value
     │ Int64   Int64      String  Int64
─────┼──────────────────────────────────
   1 │      1          1  a           1
   2 │      1          2  a           2
   3 │      2          1  a           3

julia> TulipaClustering.validate_df_and_find_key_columns(df)
2-element Vector{Symbol}:
 :timestep
 :a

julia> df = DataFrame([:value => 1])
1×1 DataFrame
 Row │ value
     │ Int64
─────┼───────
   1 │     1

julia> TulipaClustering.validate_df_and_find_key_columns(df)
ERROR: DomainError with 1×1 DataFrame
 Row │ value
     │ Int64
─────┼───────
   1 │     1:
DataFrame must contain columns `timestep` and `value`
```
"""
function validate_df_and_find_key_columns(df::AbstractDataFrame)::Vector{Symbol}
  columns = propertynames(df)
  if :timestep ∉ columns || :value ∉ columns
    throw(DomainError(df, "DataFrame must contain columns `timestep` and `value`"))
  end
  if :period ∉ columns
    throw(
      DomainError(
        df,
        "DataFrame must contain column `period`; call split_into_periods! to split it into periods.",
      ),
    )
  end
  non_key_columns = [:period, :value]
  key_columns = filter!(col -> col ∉ non_key_columns, columns)
  return key_columns
end

"""
    find_auxiliary_data(clustering_data)

Calculates auxiliary data associated with the `clustering_data`. These include:

  - `key_columns_demand`: key columns in the demand dataframe
  - `key_columns_generation_availability`: key columns in the generation availability dataframe
  - `period_duration`: duration of time periods (in time steps)
  - `last_period_duration`: duration of the last period
  - `n_periods`: total number of periods
"""
function find_auxiliary_data(clustering_data::AbstractDataFrame)
  key_columns = validate_df_and_find_key_columns(clustering_data)
  n_periods = maximum(clustering_data.period)
  period_duration = maximum(clustering_data.timestep)
  last_period_duration = maximum(clustering_data[clustering_data.period .== n_periods, :timestep])

  return AuxiliaryClusteringData(key_columns, period_duration, last_period_duration, n_periods)
end

"""
    find_period_weights(period_duration, last_period_duration, n_periods, drop_incomplete_periods)

Finds weights of two different types of periods in the clustering data:

  - complete periods: these are all of the periods with length equal to `period_duration`.
  - incomplete last period: if last period duration is less than `period_duration`, it is incomplete.
"""
function find_period_weights(
  period_duration::Int,
  last_period_duration::Int,
  n_periods::Int,
  drop_incomplete_periods::Bool,
)::Tuple{Float64, Union{Float64, Nothing}}
  if last_period_duration == period_duration
    complete_period_weight = 1.0
    incomplete_period_weight = nothing
  elseif drop_incomplete_periods
    full_period_timesteps = period_duration * (n_periods - 1)
    total_timesteps = full_period_timesteps + last_period_duration
    complete_period_weight = total_timesteps / full_period_timesteps
    incomplete_period_weight = nothing
  else
    complete_period_weight = 1.0
    incomplete_period_weight = 1.0
  end
  return complete_period_weight, incomplete_period_weight
end

"""
    df_to_matrix_and_keys(df, key_columns)

Converts a dataframe `df` (in a long format) to a matrix, ignoring the columns
specified as `key_columns`. The key columns are converted from long to wide
format and returned alongside the matrix.

# Examples

```
julia> df = DataFrame([:period => [1, 1, 2, 2], :timestep => [1, 2, 1, 2], :a .=> "a", :value => 1:4])
4×4 DataFrame
 Row │ period  timestep  a       value
     │ Int64   Int64      String  Int64
─────┼──────────────────────────────────
   1 │      1          1  a           1
   2 │      1          2  a           2
   3 │      2          1  a           3
   4 │      2          2  a           4

julia> m, k = TulipaClustering.df_to_matrix_and_keys(df, [:timestep, :a]); m
2×2 Matrix{Float64}:
 1.0  3.0
 2.0  4.0

julia> k
2×2 DataFrame
 Row │ timestep  a
     │ Int64      String
─────┼───────────────────
   1 │         1  a
   2 │         2  a
```
"""
function df_to_matrix_and_keys(df::AbstractDataFrame, key_columns::Vector{Symbol})
  wide_df = unstack(df, key_columns, :period, :value)
  matrix = select(wide_df, Not(key_columns)) |> dropmissing |> Matrix{Float64}
  keys = select(wide_df, key_columns)
  return matrix, keys
end

"""
    matrix_and_keys_to_df(matrix, keys)

Converts a a matrix `matrix` to a dataframe, appending the key columns given by
`keys`.

# Examples

```
julia> m = [1.0 3.0; 2.0 4.0]
2×2 Matrix{Float64}:
 1.0  3.0
 2.0  4.0

julia> k = DataFrame([:timestep => 1:2, :a .=> "a"])
2×2 DataFrame
 Row │ timestep  a
     │ Int64      String
─────┼───────────────────
   1 │         1  a
   2 │         2  a

julia> TulipaClustering.matrix_and_keys_to_df(m, k)
4×4 DataFrame
 Row │ rep_period  timestep  a       value
     │ Int64       Int64      String  Float64
─────┼────────────────────────────────────────
   1 │          1          1  a           1.0
   2 │          1          2  a           2.0
   3 │          2          1  a           3.0
   4 │          2          2  a           4.0
```
"""
function matrix_and_keys_to_df(matrix::Matrix{Float64}, keys::AbstractDataFrame)
  n_columns = size(matrix, 2)
  result = DataFrame(matrix, string.(1:n_columns))
  result = hcat(keys, result)            # prepend the previously deleted columns
  result = stack(result, variable_name = :rep_period) |> dropmissing # convert from wide to long format
  result.rep_period = parse.(Int, result.rep_period)  # change the type of rep_period column to Int
  select!(result, :rep_period, :timestep, :)         # move the rep_period column to the front

  return result
end

"""
    append_period_from_source_df_as_rp!(df; source_df, period, rp, key_columns)

Extracts a period with index `period` from `source_df` and appends it as a
representative period with index `rp` to `df`, using `key_columns` as keys.

# Examples

```
julia> source_df = DataFrame([:period => [1, 1, 2, 2], :timestep => [1, 2, 1, 2], :a .=> "b", :value => 5:8])
4×4 DataFrame
 Row │ period  timestep  a       value
     │ Int64   Int64      String  Int64
─────┼──────────────────────────────────
   1 │      1          1  b           5
   2 │      1          2  b           6
   3 │      2          1  b           7
   4 │      2          2  b           8

julia> df = DataFrame([:rep_period => [1, 1, 2, 2], :timestep => [1, 2, 1, 2], :a .=> "a", :value => 1:4])
4×4 DataFrame
 Row │ rep_period  timestep  a       value
     │ Int64       Int64      String  Int64
─────┼──────────────────────────────────────
   1 │          1          1  a           1
   2 │          1          2  a           2
   3 │          2          1  a           3
   4 │          2          2  a           4

julia> TulipaClustering.append_period_from_source_df_as_rp!(df; source_df, period = 2, rp = 3, key_columns = [:timestep, :a])
6×4 DataFrame
 Row │ rep_period  timestep  a       value
     │ Int64       Int64      String  Int64
─────┼──────────────────────────────────────
   1 │          1          1  a           1
   2 │          1          2  a           2
   3 │          2          1  a           3
   4 │          2          2  a           4
   5 │          3          1  b           7
   6 │          3          2  b           8
```
"""
function append_period_from_source_df_as_rp!(
  df::AbstractDataFrame;
  source_df::AbstractDataFrame,
  period::Int,
  rp::Int,
  key_columns::Vector{Symbol},
)
  period_df = source_df[source_df.period .== period, :]
  period_df.period .= rp
  select!(period_df, :period => :rep_period, key_columns..., :value)
  append!(df, period_df)
end

"""
  find_representative_periods(
    clustering_data;
    n_rp = 10,
    rescale_demand_data = true,
    drop_incomplete_last_period = false,
    method = :k_means,
    distance = SqEuclidean(),
    args...,
  )

Finds representative periods via data clustering.

  - `clustering_data`: the data to perform clustering on.
  - `n_rp`: number of representative periods to find.
  - `rescale_demand_data`: if `true`, demands are first divided by the maximum
    demand value, so that they are between zero and one like the generation
    availability data
  - `drop_incomplete_last_period`: controls how the last period is treated if it
    is not complete: if this parameter is set to `true`, the incomplete period
    is dropped and the weights are rescaled accordingly; otherwise, clustering
    is done for `n_rp - 1` periods, and the last period is added as a special
    shorter representative period
  - `method`: clustering method to use, either `:k_means` and `:k_medoids`
  - `distance`: semimetric used to measure distance between data points.
  - other named arguments can be provided; they are passed to the clustering method.
"""
function find_representative_periods(
  clustering_data::AbstractDataFrame,
  n_rp::Int;
  drop_incomplete_last_period::Bool = false,
  method::Symbol = :k_means,
  distance::SemiMetric = SqEuclidean(),
  args...,
)
  # Check that the number of RPs makes sense. The first check can be done immediately,
  # The second check is done after we compute the auxiliary data
  if n_rp < 1
    throw(ArgumentError("The number of representative periods is $n_rp but has to be at least 1."))
  end

  # Find auxiliary data and pre-compute additional constants that are used multiple times alter
  aux = find_auxiliary_data(clustering_data)
  n_periods = aux.n_periods
  if n_rp > n_periods
    throw(
      ArgumentError(
        "The number of representative periods exceeds the total number of periods, $n_rp > $n_periods.",
      ),
    )
  end
  has_incomplete_last_period = aux.last_period_duration ≠ aux.period_duration
  is_last_period_excluded = has_incomplete_last_period && !drop_incomplete_last_period
  n_complete_periods = has_incomplete_last_period ? n_periods - 1 : n_periods

  # 2. Find the weights of the two types of periods and pre-build the weight matrix.
  # We assume that the only period that can be incomplete (i.e., has a duration
  # that is less than aux.period_duration) is the very last one. All other periods
  # are complete periods.
  complete_period_weight, incomplete_period_weight = find_period_weights(
    aux.period_duration,
    aux.last_period_duration,
    n_periods,
    drop_incomplete_last_period,
  )

  # In both cases, the weights of the complete periods will be found after clustering.
  if is_last_period_excluded
    weight_matrix = sparse([n_periods], [n_rp], [incomplete_period_weight])
    n_rp -= 1  # incomplete last period becomes its own representative, exclude it from clustering
  else
    weight_matrix = spzeros(n_complete_periods, n_rp)
  end

  # 3. Build the clustering matrix

  # First, find the demand matrix and rescale it if needed
  clustering_matrix, keys = df_to_matrix_and_keys(
    clustering_data[clustering_data.period .≤ n_complete_periods, :],
    aux.key_columns,
  )

  # 4. Do the clustering, now that the data is transformed into a matrix
  if method ≡ :k_means
    # Do the clustering
    kmeans_result = kmeans(clustering_matrix, n_rp; distance, args...)

    # Reinterpret the results
    rp_matrix = kmeans_result.centers
    assignments = kmeans_result.assignments
  elseif method ≡ :k_medoids
    # Do the clustering
    # k-medoids uses distance matrix instead of clustering matrix
    distance_matrix = pairwise(distance, clustering_matrix; dims = 2)
    kmedoids_result = kmedoids(distance_matrix, n_rp; args...)

    # Reinterpret the results
    rp_matrix = clustering_matrix[:, kmedoids_result.medoids]
    assignments = kmedoids_result.assignments
  else
    throw(ArgumentError("Clustering method is not supported"))
  end

  # Fill in the weight matrix using the assignments
  for (p, rp) ∈ enumerate(assignments)
    weight_matrix[p, rp] = complete_period_weight
  end

  # 5. Reinterpret the clustering results into a format we need

  # First, convert the matrix data back to dataframes using the previously saved key columns
  rp_df = matrix_and_keys_to_df(rp_matrix, keys)

  # Next, re-append the last period if it was excluded from clustering
  if is_last_period_excluded
    n_rp += 1
    append_period_from_source_df_as_rp!(
      rp_df;
      source_df = clustering_data,
      period = n_periods,
      rp = n_rp,
      key_columns = aux.key_columns,
    )
  end

  return ClusteringResult(rp_df, weight_matrix, clustering_matrix, rp_matrix, aux)
end

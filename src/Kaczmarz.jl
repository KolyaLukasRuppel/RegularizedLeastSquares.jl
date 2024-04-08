export kaczmarz
export Kaczmarz

mutable struct Kaczmarz{matT,R,U,RN} <: AbstractRowActionSolver
  A::matT
  L2::R
  reg::Vector{RN}
  denom::Vector{U}
  rowindex::Vector{Int64}
  rowIndexCycle::Vector{Int64}
  randomized::Bool
  subMatrixSize::Int64
  probabilities::Vector{U}
  shuffleRows::Bool
  seed::Int64
  normalizeReg::AbstractRegularizationNormalization
  state::AbstractSolverState{<:Kaczmarz}
end

mutable struct KaczmarzState{T, vecT <: AbstractArray{T}} <: AbstractSolverState{Kaczmarz}
  u::vecT
  x::vecT
  vl::vecT
  εw::T
  τl::T
  αl::T
  iteration::Int64
  iterations::Int64
end

"""
    Kaczmarz(A; reg = L2Regularization(0), normalizeReg = NoNormalization(), weights=nothing, randomized=false, subMatrixFraction=0.15, shuffleRows=false, seed=1234, iterations=10, regMatrix=nothing)

Creates a Kaczmarz object for the forward operator `A`.

# Required Arguments
  * `A`                                                 - forward operator

# Optional Keyword Arguments
  * `reg::AbstractParameterizedRegularization`          - regularization term
  * `normalizeReg::AbstractRegularizationNormalization` - regularization normalization scheme; options are `NoNormalization()`, `MeasurementBasedNormalization()`, `SystemMatrixBasedNormalization()`
  * `randomized::Bool`                                    - randomize Kacmarz algorithm
  * `subMatrixFraction::Real`                             - fraction of rows used in randomized Kaczmarz algorithm
  * `shuffleRows::Bool`                                   - randomize Kacmarz algorithm
  * `seed::Int`                                           - seed for randomized algorithm
  * `iterations::Int`                                     - number of iterations

See also [`createLinearSolver`](@ref), [`solve!`](@ref).
"""
function Kaczmarz(A
                ; reg = L2Regularization(zero(real(eltype(A))))
                , normalizeReg::AbstractRegularizationNormalization = NoNormalization()
                , randomized::Bool = false
                , subMatrixFraction::Real = 0.15
                , shuffleRows::Bool = false
                , seed::Int = 1234
                , iterations::Int = 10
                )

  T = real(eltype(A))

  # Prepare regularization terms
  reg = isa(reg, AbstractVector) ? reg : [reg]
  reg = normalize(Kaczmarz, normalizeReg, reg, A, nothing)
  idx = findsink(L2Regularization, reg)
  if isnothing(idx)
    L2 = L2Regularization(zero(T))
  else
    L2 = reg[idx]
    deleteat!(reg, idx)
  end

  # Tikhonov matrix is only valid with NoNormalization or SystemMatrixBasedNormalization
  if λ(L2) isa Vector && !(normalizeReg isa NoNormalization || normalizeReg isa SystemMatrixBasedNormalization)
    error("Tikhonov matrix for Kaczmarz is only valid with no or system matrix based normalization")
  end

  indices = findsinks(AbstractProjectionRegularization, reg)
  other = AbstractRegularization[reg[i] for i in indices]
  deleteat!(reg, indices)
  if length(reg) == 1
    push!(other, reg[1])
  elseif length(reg) > 1
    error("Kaczmarz does not allow for more than one additional regularization term, found $(length(reg))")
  end
  other = identity.(other)

  # setup denom and rowindex
  A, denom, rowindex = initkaczmarz(A, λ(L2))
  rowIndexCycle = collect(1:length(rowindex))
  probabilities = eltype(denom)[]
  if randomized
    probabilities = T.(rowProbabilities(A, rowindex))
  end

  M,N = size(A)
  subMatrixSize = round(Int, subMatrixFraction*M)

  u  = zeros(eltype(A),M)
  x = zeros(eltype(A),N)
  vl = zeros(eltype(A),M)
  εw = zero(eltype(A))
  τl = zero(eltype(A))
  αl = zero(eltype(A))

  state = KaczmarzState(u, x, vl, εw, τl, αl, 0, iterations)

  return Kaczmarz(A, L2, other, denom, rowindex, rowIndexCycle,
                  randomized, subMatrixSize, probabilities, shuffleRows,
                  Int64(seed), normalizeReg, state)
end

function init!(solver::Kaczmarz, state::KaczmarzState{T, vecT}, b::otherT; kwargs...) where {T, vecT, otherT}
  u = similar(b, size(state.u)...)
  x = similar(b, size(state.x)...)
  vl = similar(b, size(state.vl)...)

  state = KaczmarzState(u, x, vl, state.εw, state.τl, state.αl, state.iteration, state.iterations)
  solver.state = state
  init!(solver, state, b; kwargs...)
end

"""
  init!(solver::Kaczmarz, b; x0 = 0)

(re-) initializes the Kacmarz iterator
"""
function init!(solver::Kaczmarz, state::KaczmarzState{T, vecT}, b::vecT; x0 = 0) where {T, vecT}
  λ_prev = λ(solver.L2)
  solver.L2  = normalize(solver, solver.normalizeReg, solver.L2,  solver.A, b)
  solver.reg = normalize(solver, solver.normalizeReg, solver.reg, solver.A, b)

  λ_ = λ(solver.L2)

  # λ changed => recompute denoms
  if λ_ != λ_prev
    # A must be unchanged, since we do not store the original SM
    _, solver.denom, solver.rowindex = initkaczmarz(solver.A, λ_)
    solver.rowIndexCycle = collect(1:length(rowindex))
    if solver.randomized
      solver.probabilities = T.(rowProbabilities(solver.A, rowindex))
    end
  end

  if solver.shuffleRows || solver.randomized
    Random.seed!(solver.seed)
  end
  if solver.shuffleRows
    shuffle!(solver.rowIndexCycle)
  end

  # start vector
  state.x .= x0
  state.vl .= 0

  state.u .= b
  if λ_ isa Vector
    state.ɛw = 0
  else
    state.ɛw = sqrt(λ_)
  end
  state.iteration = 0
end


function solversolution(solver::Kaczmarz{matT, RN}) where {matT, R<:L2Regularization{<:Vector}, RN <: Union{R, AbstractNestedRegularization{<:R}}}
  return solver.state.x .* (1 ./ sqrt.(λ(solver.L2)))
end
solversolution(solver::Kaczmarz) = solver.state.x
solverconvergence(solver::Kaczmarz) = (; :residual => norm(solver.state.vl))

function iterate(solver::Kaczmarz, state = solver.state)
  if done(solver,state) return nothing end

  if solver.randomized
    usedIndices = Int.(StatsBase.sample!(Random.GLOBAL_RNG, solver.rowIndexCycle, weights(solver.probabilities), zeros(solver.subMatrixSize), replace=false))
  else
    usedIndices = solver.rowIndexCycle
  end

  for i in usedIndices
    row = solver.rowindex[i]
    iterate_row_index(solver, state, solver.A, row, i)
  end

  for r in solver.reg
    prox!(r, solver.x)
  end

  state.iteration += 1
  return state.x, state
end

iterate_row_index(solver::Kaczmarz, state::KaczmarzState, A::AbstractLinearSolver, row, index) = iterate_row_index(solver, Matrix(A[row, :]), row, index) 
function iterate_row_index(solver::Kaczmarz, state::KaczmarzState, A, row, index)
  state.τl = dot_with_matrix_row(A,state.x,row)
  state.αl = solver.denom[index]*(state.u[row]-state.τl-state.ɛw*state.vl[row])
  kaczmarz_update!(A,state.x,row,state.αl)
  state.vl[row] += state.αl*state.ɛw
end

@inline done(solver::Kaczmarz,state::KaczmarzState) = state.iteration>=state.iterations


"""
This function calculates the probabilities of the rows of the system matrix
"""

function rowProbabilities(A, rowindex)
  normA² = rownorm²(A, 1:size(A, 1))
  p = zeros(length(rowindex))
  for i=1:length(rowindex)
    j = rowindex[i]
    p[i] = rownorm²(A, j) / (normA²)
  end
  return p
end


### initkaczmarz ###

"""
    initkaczmarz(A::AbstractMatrix,λ)

This function saves the denominators to compute αl in denom and the rowindices,
which lead to an update of x in rowindex.
"""
function initkaczmarz(A,λ)
  T = real(eltype(A))
  denom = T[]
  rowindex = Int64[]

  for i = 1:size(A, 1)
    s² = rownorm²(A,i)
    if s²>0
      push!(denom,1/(s²+λ))
      push!(rowindex,i)
    end
  end
  return A, denom, rowindex
end
function initkaczmarz(A, λ::Vector)
  λ = real(eltype(A)).(λ)
  A = initikhonov(A, λ)
  return initkaczmarz(A, 0)
end

initikhonov(A, λ) = transpose((1 ./ sqrt.(λ)) .* transpose(A)) # optimize structure for row access
initikhonov(prod::ProdOp{Tc, WeightingOp{T}, matT}, λ) where {T, Tc<:Union{T, Complex{T}}, matT} = ProdOp(prod.A, initikhonov(prod.B, λ))
### kaczmarz_update! ###

"""
    kaczmarz_update!(A::DenseMatrix{T}, x::Vector, k::Integer, beta) where T

This function updates x during the kaczmarz algorithm for dense matrices.
"""
function kaczmarz_update!(A::DenseMatrix{T}, x::Vector, k::Integer, beta) where T
  @simd for n=1:size(A,2)
    @inbounds x[n] += beta*conj(A[k,n])
  end
end

"""
    kaczmarz_update!(B::Transpose{T,S}, x::Vector,
                     k::Integer, beta) where {T,S<:DenseMatrix}

This function updates x during the kaczmarz algorithm for dense matrices.
"""
function kaczmarz_update!(B::Transpose{T,S}, x::Vector,
			  k::Integer, beta) where {T,S<:DenseMatrix}
  A = B.parent
  @inbounds @simd for n=1:size(A,1)
      x[n] += beta*conj(A[n,k])
  end
end

function kaczmarz_update!(prod::ProdOp{Tc, WeightingOp{T}, matT}, x::Vector, k, beta) where {T, Tc<:Union{T, Complex{T}}, matT}
  weight = prod.A.weights[k]
  kaczmarz_update!(prod.B, x, k, weight*beta) # only for real weights
end

# kaczmarz_update! with manual simd optimization
for (T,W, WS,shufflevectorMask,vσ) in [(Float32,:WF32,:WF32S,:shufflevectorMaskF32,:vσF32),(Float64,:WF64,:WF64S,:shufflevectorMaskF64,:vσF64)]
    eval(quote
        const $WS = VectorizationBase.pick_vector_width($T)
        const $W = Int(VectorizationBase.pick_vector_width($T))
        const $shufflevectorMask = Val(ntuple(k -> iseven(k-1) ? k : k-2, $W))
        const $vσ = Vec(ntuple(k -> (-1f0)^(k+1),$W)...)
        function kaczmarz_update!(A::Transpose{Complex{$T},S}, b::Vector{Complex{$T}}, k::Integer, beta::Complex{$T}) where {S<:DenseMatrix}
            b = reinterpret($T,b)
            A = reinterpret($T,A.parent)

            N = length(b)
            Nrep, Nrem = divrem(N,4*$W) # main loop
            Mrep, Mrem = divrem(Nrem,$W) # last iterations
            idx = MM{$W}(1)
            iOffset = 4*$W

            vβr = vbroadcast($WS, beta.re) * $vσ # vector containing (βᵣ,-βᵣ,βᵣ,-βᵣ,...)
            vβi = vbroadcast($WS, beta.im) # vector containing (βᵢ,βᵢ,βᵢ,βᵢ,...)

            GC.@preserve b A begin # protect A and y from GC
                vptrA = stridedpointer(A)
                vptrb = stridedpointer(b)
                for _ = 1:Nrep
                    Base.Cartesian.@nexprs 4 i -> vb_i = vload(vptrb, ($W*(i-1) + idx,))
                    Base.Cartesian.@nexprs 4 i -> va_i = vload(vptrA, ($W*(i-1) + idx,k))
                    Base.Cartesian.@nexprs 4 i -> begin
                        vb_i = muladd(va_i, vβr, vb_i)
                        va_i = shufflevector(va_i, $shufflevectorMask)
                        vb_i = muladd(va_i, vβi, vb_i)
                    	vstore!(vptrb, vb_i, ($W*(i-1) + idx,))
                    end
                    idx += iOffset
                end

                for _ = 1:Mrep
	            vb = vload(vptrb, (idx,))
	            va = vload(vptrA, (idx,k))
                    vb = muladd(va, vβr, vb)
                    va = shufflevector(va, $shufflevectorMask)
                    vb = muladd(va, vβi, vb)
		            vstore!(vptrb, vb, (idx,))
                    idx += $W
                end

                if Mrem!=0
                    vloadMask = VectorizationBase.mask($T, Mrem)
                    vb = vload(vptrb, (idx,), vloadMask)
                    va = vload(vptrA, (idx,k), vloadMask)
                    vb = muladd(va, vβr, vb)
                    va = shufflevector(va, $shufflevectorMask)
                    vb = muladd(va, vβi, vb)
                    vstore!(vptrb, vb, (idx,), vloadMask)
                end
            end # GC.@preserve
        end
    end)
end

#=
@doc "This function updates x during the kaczmarz algorithm for dense matrices." ->
function kaczmarz_update!{T}(A::Matrix{T}, x::Vector{T}, k::Integer, beta::T)
  BLAS.axpy!(length(x), beta, pointer(A,sub2ind(size(A),1,k)), 1, pointer(x), 1)
end
=#

"""
    kaczmarz_update!(B::Transpose{T,S}, x::Vector,
                          k::Integer, beta) where {T,S<:SparseMatrixCSC}

This funtion updates x during the kaczmarz algorithm for sparse matrices.
"""
function kaczmarz_update!(B::Transpose{T,S}, x::Vector,
                          k::Integer, beta) where {T,S<:SparseMatrixCSC}
  A = B.parent
  N = A.colptr[k+1]-A.colptr[k]
  for n=A.colptr[k]:N-1+A.colptr[k]
    @inbounds x[A.rowval[n]] += beta*conj(A.nzval[n])
  end
end

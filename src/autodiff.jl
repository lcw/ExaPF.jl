
module AutoDiff

using SparseArrays

using CUDA
import CUDA.CUSPARSE
import ForwardDiff
import SparseDiffTools

using ..ExaPF: Spmat, xzeros, State, Control

import Base: show

"""
    AbstractJacobian

Automatic differentiation for the compressed Jacobians of the
constraints `g(x,u)` with respect to the state `x` and the control `u`
(here called design).

TODO: Use dispatch to unify the code of the state and control Jacobian.
This is currently not done because the abstraction of the indexing is not yet resolved.

"""
abstract type AbstractJacobian end
struct StateJacobian <: AbstractJacobian end
struct ControlJacobian <: AbstractJacobian end
abstract type AbstractHessian end
struct StateStateHessian <: AbstractHessian end
struct ControlStateHessian <: AbstractHessian end
struct ControlControlHessian <: AbstractHessian end
t1s{N,V} = ForwardDiff.Dual{Nothing,V, N} where {N,V}
t2s{M,N,V} =  ForwardDiff.Dual{Nothing,t1s{N,V}, M} where {M,N,V}

function _init_seed!(t1sseeds, coloring, ncolor, nmap)
    t1sseedvec = zeros(Float64, ncolor)
    @inbounds for i in 1:nmap
        for j in 1:ncolor
            if coloring[i] == j
                t1sseedvec[j] = 1.0
            end
        end
        t1sseeds[i] = ForwardDiff.Partials{ncolor, Float64}(NTuple{ncolor, Float64}(t1sseedvec))
        t1sseedvec .= 0
    end
end

"""
    Jacobian

Creates an object for the Jacobian

* `J::SMT`: Sparse uncompressed Jacobian to be used by linear solver. This is either of type `SparseMatrixCSC` or `CuSparseMatrixCSR`.
* `compressedJ::MT`: Dense compressed Jacobian used for updating values through AD either of type `Matrix` or `CuMatrix`.
* `coloring::VI`: Row coloring of the Jacobian.
* `t1sseeds::VP`: The seeding vector for AD built based on the coloring.
* `t1sF::VD`: Output array of active (AD) type.
* `x::VT`: Input array of passive type. This includes both state and control.
* `t1sx::VD`: Input array of active type.
* `map::VI`: State and control mapping to array `x`
* `varx::SubT`: View of `map` on `x`
* `t1svarx::SubD`: Active (AD) view of `map` on `x`
"""
struct Jacobian{VI, VT, MT, SMT, VP, VD, SubT, SubD}
    J::SMT
    compressedJ::MT
    coloring::VI
    t1sseeds::VP
    t1sF::VD
    x::VT
    t1sx::VD
    map::VI
    # Cache views on x and its dual vector to avoid reallocating on the GPU
    varx::SubT
    t1svarx::SubD
    function Jacobian(structure, F, v_m, v_a, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus, type)
        nv_m = length(v_m)
        nv_a = length(v_a)
        npbus = length(pinj)
        nref = length(ref)
        if F isa Array
            VI = Vector{Int}
            VT = Vector{Float64}
            MT = Matrix{Float64}
            SMT = SparseMatrixCSC
            A = Vector
        elseif F isa CUDA.CuArray
            VI = CUDA.CuVector{Int}
            VT = CUDA.CuVector{Float64}
            MT = CUDA.CuMatrix{Float64}
            SMT = CUSPARSE.CuSparseMatrixCSR
            A = CUDA.CuVector
        else
            error("Wrong array type ", typeof(F))
        end

        map = VI(structure.map)
        nmap = length(structure.map)
        # Need a host arrays for the sparsity detection below
        spmap = Vector(map)
        hybus_re = Spmat{Vector{Int}, Vector{Float64}}(ybus_re)
        hybus_im = Spmat{Vector{Int}, Vector{Float64}}(ybus_im)
        n = nv_a
        Yre = SparseMatrixCSC{Float64,Int64}(n, n, hybus_re.colptr, hybus_re.rowval, hybus_re.nzval)
        Yim = SparseMatrixCSC{Float64,Int64}(n, n, hybus_im.colptr, hybus_im.rowval, hybus_im.nzval)
        Y = Yre .+ 1im .* Yim
        # Randomized inputs
        Vre = Float64.([i for i in 1:n])
        Vim = Float64.([i for i in n+1:2*n])
        V = Vre .+ 1im .* Vim
        if isa(type, StateJacobian)
            variable = State()
        else
            variable = Control()
        end
        J = structure.sparsity(variable, V, Y, pv, pq, ref)
        coloring = VI(SparseDiffTools.matrix_colors(J))
        ncolor = size(unique(coloring),1)
        if F isa CUDA.CuArray
            J = CUSPARSE.CuSparseMatrixCSR(J)
        end
        t1s{N} = ForwardDiff.Dual{Nothing,Float64, N} where N
        if isa(type, StateJacobian)
            x = VT(zeros(Float64, nv_m + nv_a))
            t1sx = A{t1s{ncolor}}(x)
            t1sF = A{t1s{ncolor}}(zeros(Float64, nmap))
            t1sseeds = A{ForwardDiff.Partials{ncolor,Float64}}(undef, nmap)
            _init_seed!(t1sseeds, coloring, ncolor, nmap)
            compressedJ = MT(zeros(Float64, ncolor, nmap))
            varx = view(x, map)
            t1svarx = view(t1sx, map)
        elseif isa(type, ControlJacobian)
            x = VT(zeros(Float64, npbus + nv_a))
            t1sx = A{t1s{ncolor}}(x)
            t1sF = A{t1s{ncolor}}(zeros(Float64, length(F)))
            t1sseeds = A{ForwardDiff.Partials{ncolor,Float64}}(undef, nmap)
            _init_seed!(t1sseeds, coloring, ncolor, nmap)
            compressedJ = MT(zeros(Float64, ncolor, length(F)))
            varx = view(x, map)
            t1svarx = view(t1sx, map)
        else
            error("Unsupported Jacobian type. Must be either ControlJacobian or StateJacobian.")
        end

        VP = typeof(t1sseeds)
        VD = typeof(t1sx)
        return new{VI, VT, MT, SMT, VP, VD, typeof(varx), typeof(t1svarx)}(
            J, compressedJ, coloring, t1sseeds, t1sF, x, t1sx, map, varx, t1svarx
        )
    end
end

"""
    seed_kernel_cpu!
Seeding on the CPU, not parallelized.
"""
function seed_kernel_cpu!(
    duals::AbstractArray{ForwardDiff.Dual{T,V,N}}, x,
    seeds::AbstractArray{ForwardDiff.Partials{N,V}}
) where {T,V,N}
    for i in 1:size(duals,1)
        duals[i] = ForwardDiff.Dual{T,V,N}(x[i], seeds[i])
    end
end

"""
    seed_kernel_gpu!
Seeding on GPU parallelized over the `ncolor` number of duals
"""
function seed_kernel_gpu!(
    duals::AbstractArray{ForwardDiff.Dual{T,V,N}}, x,
    seeds::AbstractArray{ForwardDiff.Partials{N,V}}
) where {T,V,N}
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride = blockDim().x * gridDim().x
    for i in index:stride:size(duals,1)
        duals[i] = ForwardDiff.Dual{T,V,N}(x[i], seeds[i])
    end
end

"""
    seed_kernel!
Calling the GPU seeding kernel
"""
function seed_kernel!(t1sseeds::CuVector{ForwardDiff.Partials{N,V}}, varx, t1svarx, nbus) where {N, V}
    nthreads = 256
    nblocks = div(nbus, nthreads, RoundUp)
    CUDA.@sync begin
        @cuda threads=nthreads blocks=nblocks seed_kernel_gpu!(
            t1svarx,
            varx,
            t1sseeds,
        )
    end
end

"""
    seed_kernel!(t1sseeds::Vector{ForwardDiff.Partials{N,V}}, varx, t1svarx, nbus) where {N, V}
Calling the CPU seeding kernel
"""
function seed_kernel!(t1sseeds::Vector{ForwardDiff.Partials{N,V}}, varx, t1svarx, nbus) where {N, V}
    seed_kernel_cpu!(t1svarx, varx, t1sseeds)
end

"""
    getpartials_kernel_cpu!(compressedJ, t1sF)

Extract the partials from the AutoDiff dual type on the CPU and put it in the
compressed Jacobian

"""
function getpartials_kernel_cpu!(compressedJ, t1sF)
    for i in 1:size(t1sF,1) # Go over outputs
        compressedJ[:, i] .= ForwardDiff.partials.(t1sF[i]).values
    end
end

"""
    getpartials_kernel_gpu!(compressedJ, t1sF)

Extract the partials from the AutoDiff dual type on the GPU and put it in the
compressed Jacobian

"""
function getpartials_kernel_gpu!(compressedJ, t1sF)
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride = blockDim().x * gridDim().x
    for i in index:stride:size(t1sF, 1) # Go over outputs
        for j in eachindex(ForwardDiff.partials.(t1sF[i]).values)
            @inbounds compressedJ[j, i] = ForwardDiff.partials.(t1sF[i]).values[j]
        end
    end
end

"""
    getpartials_kernel!(compressedJ::CuArray{T, 2}, t1sF, nbus) where T

Calling the GPU partial extraction kernel

"""
function getpartials_kernel!(compressedJ::CUDA.CuArray{T, 2}, t1sF, nbus) where T
    nthreads = 256
    nblocks = div(nbus, nthreads, RoundUp)
    CUDA.@sync begin
        CUDA.@cuda threads=nthreads blocks=nblocks getpartials_kernel_gpu!(
            compressedJ,
            t1sF
        )
    end
end

"""
    getpartials_kernel!(compressedJ::Array{T, 2}, t1sF, nbus) where T

Calling the CPU partial extraction kernel

"""
function getpartials_kernel!(compressedJ::Array{T, 2}, t1sF, nbus) where T
    getpartials_kernel_cpu!(compressedJ, t1sF)
end

"""
    uncompress_kernel_gpu!(J_nzVal, J_rowPtr, J_colVal, compressedJ, coloring, nmap)

Uncompress the compressed Jacobian matrix from `compressedJ` to sparse CSR on
the GPU. Only bitarguments are allowed for the kernel.
(for GPU only) TODO: should convert to @kernel
"""
function uncompress_kernel_gpu!(J_nzVal, J_rowPtr, J_colVal, compressedJ, coloring, nmap)
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride = blockDim().x * gridDim().x
    for i in index:stride:nmap
        for j in J_rowPtr[i]:J_rowPtr[i+1]-1
            @inbounds J_nzVal[j] = compressedJ[coloring[J_colVal[j]], i]
        end
    end
end

"""
    uncompress_kernel!(J::SparseArrays.SparseMatrixCSC, compressedJ, coloring)

Uncompress the compressed Jacobian matrix from `compressedJ` to sparse CSC on
the CPU.
"""
function uncompress_kernel!(J::SparseArrays.SparseMatrixCSC, compressedJ, coloring)
    # CSC is column oriented: nmap is equal to number of columns
    nmap = size(J, 2)
    @assert(maximum(coloring) == size(compressedJ,1))
    for i in 1:nmap
        for j in J.colptr[i]:J.colptr[i+1]-1
            @inbounds J.nzval[j] = compressedJ[coloring[i], J.rowval[j]]
        end
    end
end

"""
    uncompress_kernel!(J::SparseArrays.SparseMatrixCSC, compressedJ, coloring, coloring)

Uncompress the compressed Jacobian matrix from `compressedJ` to sparse CSC on
the CPU.
"""
function uncompress_kernel!(H::SparseArrays.SparseMatrixCSC, compressedH, lambda, coloring1, coloring2)
    # CSC is column oriented: nmap is equal to number of columns
    n1 = size(H, 1)
    n2 = size(H, 2)
    n = length(lambda)
    for i in 1:n1
        for j in H.colptr[i]:H.colptr[i+1]-1 
            sum = 0.0
            for k in 1:n
                sum += lambda[k]*compressedH[i, H.rowval[j], k]
            end
            @inbounds H.nzval[j] = sum
        end
    end
end

"""
    uncompress_kernel!(J::CUDA.CUSPARSE.CuSparseMatrixCSR, compressedJ, coloring)

Uncompress the compressed Jacobian matrix from `compressedJ` to sparse CSC on
the GPU by calling the kernel [`uncompress_kernel_gpu!`](@ref).
"""
function uncompress_kernel!(J::CUSPARSE.CuSparseMatrixCSR, compressedJ, coloring)
    # CSR is row oriented: nmap is equal to number of rows
    nmap = size(J, 1)
    nthreads = 256
    nblocks = div(nmap, nthreads, RoundUp)
    CUDA.@sync begin
        CUDA.@cuda threads=nthreads blocks=nblocks uncompress_kernel_gpu!(
                J.nzVal,
                J.rowPtr,
                J.colVal,
                compressedJ,
                coloring, nmap
        )
    end
end

"""
    residual_jacobian!(arrays::StateJacobian,
                        residual_polar!,
                        v_m, v_a, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus,
                        timer = nothing)

Update the sparse Jacobian entries using AutoDiff. No allocations are taking place in this function.

* `arrays::StateJacobian`: Factory created Jacobian object to update
* `residual_polar`: Primal function
* `v_m, v_a, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus`: Inputs both
  active and passive parameters. Active inputs are mapped to `x` via the preallocated views.

"""
function residual_jacobian!(arrays::Jacobian,
                             residual_polar!,
                             v_m, v_a, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus,
                             type::AbstractJacobian)
    nvbus = length(v_m)
    ninj = length(pinj)
    if isa(type, StateJacobian)
        arrays.x[1:nvbus] .= v_m
        arrays.x[nvbus+1:2*nvbus] .= v_a
        arrays.t1sx .= arrays.x
        arrays.t1sF .= 0.0
    elseif isa(type, ControlJacobian)
        arrays.x[1:nvbus] .= v_m
        arrays.x[nvbus+1:nvbus+ninj] .= pinj
        arrays.t1sx .= arrays.x
        arrays.t1sF .= 0.0
    else
        error("Unsupported Jacobian structure")
    end

    seed_kernel!(arrays.t1sseeds, arrays.varx, arrays.t1svarx, nbus)

    if isa(type, StateJacobian)
        residual_polar!(
            arrays.t1sF,
            view(arrays.t1sx, 1:nvbus),
            view(arrays.t1sx, nvbus+1:2*nvbus),
            ybus_re, ybus_im,
            pinj, qinj,
            pv, pq, nbus
        )
    elseif isa(type, ControlJacobian)
        residual_polar!(
            arrays.t1sF,
            view(arrays.t1sx, 1:nvbus),
            v_a,
            ybus_re, ybus_im,
            view(arrays.t1sx, nvbus+1:nvbus+ninj), qinj,
            pv, pq, nbus
        )
    else
        error("Unsupported Jacobian structure")
    end

    getpartials_kernel!(arrays.compressedJ, arrays.t1sF, nbus)
    uncompress_kernel!(arrays.J, arrays.compressedJ, arrays.coloring)

    return nothing
end

function Base.show(io::IO, jacobian::AbstractJacobian)
    ncolor = size(unique(jacobian.coloring), 1)
    print(io, "Number of Jacobian colors: ", ncolor)
end

"""
    StateHessianAD

Creates an object for the state Jacobian

* `J::SMT`: Sparse uncompressed Jacobian to be used by linear solver. This is either of type `SparseMatrixCSC` or `CuSparseMatrixCSR`.
* `compressedJ::MT`: Dense compressed Jacobian used for updating values through AD either of type `Matrix` or `CuMatrix`.
* `coloring::VI`: Row coloring of the Jacobian.
* `t1sseeds::VP`: The seeding vector for AD built based on the coloring.
* `t1sF::VD`: Output array of active (AD) type.
* `x::VT`: Input array of passive type. This includes both state and control.
* `t1sx::VD`: Input array of active type.
* `map::VI`: State and control mapping to array `x`
* `varx::SubT`: View of `map` on `x`
* `t1svarx::SubD`: Active (AD) view of `map` on `x`
"""
struct Hessian{VI, VT, MT, SMT, VP, VP2, VD, SubT, SubD}
    H::SMT
    compressedH::MT
    coloring::VI
    t1sseeds::VP
    t2sseeds::VP2
    t2sF::VD
    x::VT
    t2sx::VD
    map::VI
    # Cache views on x and its dual vector to avoid reallocating on the GPU
    varx::SubT
    t2svarx::SubD
    function Hessian(structure, F, v_m, v_a, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus, type)
        nv_m = length(v_m)
        nv_a = length(v_a)
        npbus = length(pinj)
        nref = length(ref)
        if F isa Array
            VI = Vector{Int}
            VT = Vector{Float64}
            MT = Array{Float64, 3}
            SMT = SparseMatrixCSC
            A = Vector
        elseif F isa CuArray
            VI = CuVector{Int}
            VT = CuVector{Float64}
            MT = CuMatrix{Float64}
            SMT = CuSparseMatrixCSR
            A = CuVector
        else
            error("Wrong array type ", typeof(F))
        end

        mappv = [i + nv_m for i in pv]
        mappq = [i + nv_m for i in pq]
        # Ordering for x is (θ_pv, θ_pq, v_pq)
        # map = VI(vcat(mappv, mappq, pq))
        map = VI(structure.map)
        nmap = size(map,1)

        # Need a host arrays for the sparsity detection below
        spmap = Vector(map)
        hybus_re = Spmat{Vector{Int}, Vector{Float64}}(ybus_re)
        hybus_im = Spmat{Vector{Int}, Vector{Float64}}(ybus_im)
        n = nv_a
        Yre = SparseMatrixCSC{Float64,Int64}(n, n, hybus_re.colptr, hybus_re.rowval, hybus_re.nzval)
        Yim = SparseMatrixCSC{Float64,Int64}(n, n, hybus_im.colptr, hybus_im.rowval, hybus_im.nzval)
        Y = Yre .+ 1im .* Yim
        # Randomized inputs
        Vre = Float64.([i for i in 1:n])
        Vim = Float64.([i for i in n+1:2*n])
        V = Vre .+ 1im .* Vim
        # J = residualJacobian(V, Y, pv, pq)
        J = structure.sparsity(State(), V, Y, pv, pq, ref)
        # coloring = VI(SparseDiffTools.matrix_colors(J))
        coloring = [i for i in 1:length(map)]
        @show coloring
        ncolor = size(unique(coloring),1)
        if F isa CUDA.CuArray
            J = CUSPARSE.CuSparseMatrixCSR(J)
        end
        H = copy(J)   
        x = VT(zeros(Float64, nv_m + nv_a))
        t2sx = A{t2s{ncolor,ncolor,Float64}}(x)
        t2sF = A{t2s{ncolor,ncolor,Float64}}(zeros(Float64, nmap))
        t1sseeds = A{ForwardDiff.Partials{ncolor,Float64}}(undef, nmap)
        t2sseeds = A{ForwardDiff.Partials{ncolor,t1s{ncolor,Float64}}}(undef, nmap)
        @show typeof(t2sseeds)
        _init_seed!(t1sseeds, coloring, ncolor, nmap)
        _init_seed!(t2sseeds, coloring, ncolor, nmap)

        compressedH = MT(zeros(Float64, ncolor, ncolor, nmap))
        nthreads=256
        nblocks=ceil(Int64, nmap/nthreads)
        # Views
        # @show map
        # @show length(x)
        varx = view(x, map)
        t2svarx = view(t2sx, map)
        VP = typeof(t1sseeds)
        VP2 = typeof(t2sseeds)
        VD = typeof(t2sx)
        return new{VI, VT, MT, SMT, VP, VP2, VD, typeof(varx), typeof(t2svarx)}(
            H, compressedH, coloring, t1sseeds, t2sseeds, t2sF, x, t2sx, map, varx, t2svarx
        )
    end
end
function getpartials(compressedH::Array{T, 3}, t2sF) where T
    for i in 1:length(t2sF)
        for j in 1:size(compressedH, 2)
            compressedH[:,j,i] .= t2sF[i].partials[j].partials
        end
    end
end

"""
    seed_kernel_cpu!
Seeding on the CPU, not parallelized.
"""
function seed_kernel_cpu!(t2sseeds::AbstractArray{ForwardDiff.Partials{M,t1s{N,V}}}, t1sseeds::AbstractArray{ForwardDiff.Partials{N,V}}, varx, t2svarx::AbstractArray{ForwardDiff.Dual{T,t1s{N,V},M}}) where {T,V,M,N}
    t1svarx = t1s{N,V}.(varx)
    for i in 1:length(t2svarx)
        t2svarx[i] = ForwardDiff.Dual{T,t1s{N,V},M}(t1s{N,V}(varx[i], t1sseeds[i]), t2sseeds[i])
    end
end

"""
    seed_kernel_gpu!
Seeding on GPU parallelized over the `ncolor` number of duals
"""
function seed_kernel_gpu!(
    duals::AbstractArray{ForwardDiff.Dual{T,V,N}}, x,
    seeds::AbstractArray{ForwardDiff.Partials{N,V}}
) where {T,V,N}
    index = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    stride = blockDim().x * gridDim().x
    for i in index:stride:size(duals,1)
        duals[i] = ForwardDiff.Dual{T,V,N}(x[i], seeds[i])
    end
end

"""
    seed_kernel!
Calling the GPU seeding kernel
"""
function seed_kernel!(t1sseeds::CuVector{ForwardDiff.Partials{N,V}}, varx, t1svarx, nbus) where {N, V}
    nthreads = 256
    nblocks = div(nbus, nthreads, RoundUp)
    CUDA.@sync begin
        @cuda threads=nthreads blocks=nblocks seed_kernel_gpu!(
            t1svarx,
            varx,
            t1sseeds,
        )
    end
end

"""
    seed_kernel!(t1sseeds::Vector{ForwardDiff.Partials{N,V}}, varx, t1svarx, nbus) where {N, V}
Calling the CPU seeding kernel
"""
function seed_kernel!(lambda::AbstractVector, t1sseeds::AbstractArray{ForwardDiff.Partials{N,V}}, varx, t2svarx::AbstractArray{ForwardDiff.Dual{T,t1s{N,V},M}}) where {T,V,M,N}
    seed_kernel_cpu!(lambda, t1sseeds, varx, t2svarx)
end

function residual_hessian_vecprod!(arrays::Hessian,
                             residual_polar!,
                             vm, va, ybus_re, ybus_im, pinj, qinj, pv, pq, ref, nbus,
                             lambda::AbstractVector, type::AbstractHessian)
    nvbus = length(vm)
    nmap = size(arrays.map, 1)
    arrays.x[1:nvbus] .= vm
    arrays.x[nvbus+1:2*nvbus] .= va
    arrays.t2sx .= arrays.x
    arrays.t2sF .= 0.0

    seed_kernel_cpu!(arrays.t2sseeds, arrays.t1sseeds, arrays.varx, arrays.t2svarx)

    residual_polar!(
        arrays.t2sF,
        view(arrays.t2sx, 1:nvbus),
        view(arrays.t2sx, nvbus+1:2*nvbus),
        ybus_re, ybus_im,
        pinj, qinj,
        pv, pq, nbus
    )

    getpartials(arrays.compressedH, arrays.t2sF)
    # uncompress_kernel!(arrays.H, arrays.compressedH, arrays.coloring)
    uncompress_kernel!(arrays.H, arrays.compressedH, lambda, arrays.coloring, arrays.coloring)
    return nothing
end

end

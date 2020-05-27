module Precondition

using LightGraphs
using Metis
using SparseArrays
using LinearAlgebra
using CuArrays
using CuArrays.CUSPARSE
using CUDAnative

cuzeros = CuArrays.zeros

mutable struct Preconditioner
  npart::Int64
  partitions::Vector{Vector{Int64}}
  Js
  cuJs
  P
  function Preconditioner(J, npart)
    adj = build_adjmatrix(J)
    g = Graph(adj)
    m = size(J,1)
    n = size(J,2)
    @show m,n
    part = Metis.partition(g, npart)
    partitions = Vector{Vector{Int64}}()
    # cupartitions = Vector{CuVector{Int64}}(undef, npart)
    for i in 1:npart
      push!(partitions, [])
    end
    for (i,v) in enumerate(part)
      push!(partitions[v], i)
    end
    # for i in 1:npart
    #   cupartitions[i] = CuVector{Int64}(partitions[i])
    # end
    Js = Vector{Matrix{Float64}}(undef, npart)
    for i in 1:npart
      Js[i] = zeros(Float64, length(partitions[i]), length(partitions[i]))
    end
    if Main.target == "cuda"
      global cuJs = Vector{CuMatrix{Float64}}(undef, length(partitions))
      for i in 1:length(partitions)
        cuJs[i] = cuzeros(Float64, length(partitions[i]), length(partitions[i]))
        cuJs[i][:] = J[partitions[i],partitions[i]]
      end
      rowPtr = CuVector{Cint}(undef, npart+1)
      for i in 1:npart+1
        rowPtr[i] = Cint(i)
      end
      colVal = CuVector{Cint}(undef, 2)
      for i in 1:npart
        colVal[i] = Cint(i)
      end
      blockDim::Cint = m/npart 
      nzVal = CuVector{Float64}(undef, 2*blockDim^2)
      dims::NTuple{2,Int} = (m,n)
      dir = 'R'
      nnz::Cint = blockDim^2*2
      P = CuSparseMatrixBSR{Float64}(rowPtr, colVal, nzVal, dims::NTuple{2,Int},blockDim::Cint, dir, nnz::Cint)
    else
      global cuJs = nothing
      global P = copy(J)
    end
    return new(npart, partitions, Js, cuJs, P)# cuJs, P)
  end
end

  function build_adjmatrix(A)
      rows = Int64[]
      cols = Int64[]
      vals = Float64[]
      @show size(A)
      rowsA = rowvals(A)
      m, n = size(A)
      for i = 1:n
          for j in nzrange(A, i)
              push!(rows, rowsA[j])
              push!(cols, i)
              push!(vals, 1.0)

              push!(rows, i)
              push!(cols, rowsA[j])
              push!(vals, 1.0)
          end
      end
      println("Creating matrix")
      return sparse(rows,cols,vals,size(A,1),size(A,2))
  end

  function update(J, p::Preconditioner)
    if J isa CuSparseMatrixCSR
      for i in 1:length(p.partitions)
        p.cuJs[i][:] = J[p.partitions[i],p.partitions[i]]
      end
      pivot, info = CuArrays.CUBLAS.getrf_batched!(p.cuJs, true)
      CuArrays.@sync pivot, info, cuJs = CuArrays.CUBLAS.getri_batched(p.cuJs, pivot)
      p.P.nzVal[1:11*11] = p.cuJs[1][:]
      p.P.nzVal[11*11+1:end] = p.cuJs[2][:]
    else
      for i in 1:length(p.partitions)
        p.Js[i] = J[p.partitions[i],p.partitions[i]]
        p.Js[i] = inv(p.Js[i])
      end
      p.P.nzval .= 0 
      for i in 1:length(p.partitions)
        p.P[p.partitions[i], p.partitions[i]] += p.Js[i]
      end
    end
    return p.P
  end
end

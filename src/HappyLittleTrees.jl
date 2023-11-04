module HappyLittleTrees
export AMT

using StaticArrays

const B = 6
const CAPACITY = 2B - 1
const HALFCAP = B - 1

"""
ArrayMappedTrie

An efficient mapping from UInt64 to values. Performs about ~2-3 times slower
  than a Julia Dict and uses 1-2 times as much memory. However, can be used in
  a persistent/copy-on-write manner without much degradation of performance.
  Additionally, stores the data in sorted order with better performance than
  a binary tree.

Reference: http://lampwww.epfl.ch/papers/idealhashtrees.pdf

Conceptually, you can think of this as

struct AMT{T}
  children::SVector{64, Union{Nothing, Pair{UInt64, T}, AMT{T}}}
end

This is then indexed in the normal trie manner, i.e. you treat a UInt64
  as an array of 6 bit chunks, and follow a path down the tree until you hit
  a leaf.

However, this would be horribly space inefficient. Therefore, we instead
  store using a UInt64 as a bitmap the array indices that are leaves,
  and we use another UInt64 to store the array indices that are other
  nodes. We can then store only the non-null leaves/children in separate
  arrays. To index into these arrays, we take advantage of the CPU
  "popcount" instruction, which counts the number of 1s in a word.
  By masking out the higher bits, we can in two CPU instructions count
  the number of bits up to a given bit, which gives us our indices
  into the keyvals/children arrays.

TODO: make persistent version.
"""
mutable struct AMT{T}
  keyvals::Vector{Pair{UInt64, T}}
  isval::UInt64
  children::Vector{AMT{T}}
  ischild::UInt64
  function AMT{T}() where {T}
    new(Pair{UInt64, T}[], UInt64(0), AMT{T}[], UInt64(0))
  end
end

const MASK6 = UInt64((1 << 6) - 1)
const INCREMENT = UInt16(6)

function section(x::UInt64, i::UInt16)
  xi = (x & (MASK6 << i)) >> i
  xibit = UInt64(1) << xi
  ximask = (xibit << 1) - UInt64(1)
  (xibit, ximask)
end

function _get(t::AMT, x::UInt64, i::UInt16=UInt16(0))
  if i > 63
    return nothing
  end
  (xibit, ximask) = section(x, i)
  if !iszero(t.isval & xibit)
    idx = count_ones(t.isval & ximask)
    (y, v) = t.keyvals[idx]
    if y == x
      v
    else
      nothing
    end
  elseif !iszero(t.ischild & xibit)
    _get(t.children[count_ones(t.ischild & ximask)], x, i + INCREMENT)
  else
    nothing
  end
end

Base.getindex(t::AMT, x::Integer) = _get(t, UInt64(x))

function _set!(t::AMT{T}, v::T, x::UInt64, i::UInt16=UInt16(0)) where {T}
  (xibit, ximask) = section(x, i)
  if !iszero(t.isval & xibit)
    idx = count_ones(t.isval & ximask)
    (y, v′) = t.keyvals[idx]
    if y == x # update in this vector
      t.keyvals[idx] = x => v
    else # make new child
      deleteat!(t.keyvals, idx)
      t.ischild = t.ischild | xibit
      t.isval = t.isval & (~xibit)
      cidx = count_ones(t.ischild & ximask)
      child = AMT{T}()
      _set!(child, v, x, i + INCREMENT)
      _set!(child, v′, y, i + INCREMENT)
      insert!(t.children, cidx, child)
    end
  elseif !iszero(t.ischild & xibit)
    _set!(t.children[count_ones(t.ischild & ximask)], v, x, i + INCREMENT)
  else # make new value in this node
    t.isval = t.isval | xibit
    idx = count_ones(t.isval & ximask)
    insert!(t.keyvals, idx, x => v)
  end
end

Base.setindex!(t::AMT{T}, v::T, x::Integer) where {T} = _set!(t, v, UInt64(x))

end # module HappyLittleTrees

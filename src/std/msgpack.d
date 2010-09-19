// Written in the D programming language.

/**
 * MessagePack serializer and deserializer implementation.
 *
 * MessagePack is a binary-based serialization specification.
 *
 * Example:
 * -----
 * auto data = tuple("MessagePack!", [1, 2], true);
 *
 * auto serialized = pack(data);
 *
 * // ...
 *
 * typeof(data) deserialized;
 *
 * unpack(serialized, deserialized);
 *
 * assert(data == deserialized);
 * -----
 *
 * See_Also:
 *  $(LINK2 http://msgpack.org/, The MessagePack Project)$(BR)
 *  $(LINK2 http://redmine.msgpack.org/projects/msgpack/wiki/FormatDesign, MessagePack Design concept)$(BR)
 *  $(LINK2 http://redmine.msgpack.org/projects/msgpack/wiki/FormatSpec, MessagePack data format)
 *
 * Copyright: Copyright Masahiro Nakagawa 2010.
 * License:   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
 * Authors:   Masahiro Nakagawa
 *
 *          Copyright Masahiro Nakagawa 2010.
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          http://www.boost.org/LICENSE_1_0.txt)
 */
module std.msgpack;

import std.array;
import std.exception;
import std.range;
import std.stdio;
import std.traits;
import std.typetuple;

// for VRefBuffer
version(Posix)
{
    import core.sys.posix.sys.uio : iovec;
}
else
{
    /**
     * from core.sys.posix.sys.uio.iovec for compatibility with posix.
     */
    struct iovec
    {
        void*  iov_base;
        size_t iov_len;
    }
}

// for Converting Endian using ntohs and ntohl;
version (Windows)
{
    import std.c.windows.winsock;
}
else
{
    import core.sys.posix.arpa.inet;
}

static if (real.sizeof == double.sizeof) {
    // for 80bit real inter-operation on non-x86 CPU
    version = NonX86;

    import std.numeric;
}

version(unittest) import std.file, std.typecons, std.c.string;


@trusted:


// Buffer implementations


/**
 * $(D VRefBuffer) is a zero copy buffer for more efficient serialization
 *
 * Example:
 * -----
 * auto packer = packer(vrefBuffer(16));  // threshold is 16
 *
 * // packs data
 *
 * writev(fd, cast(void*)packer.buffer.vector.ptr, packer.buffer.vector.length);
 * -----
 *
 * See_Also:
 *  $(LINK http://redmine.msgpack.org/projects/msgpack/wiki/Introduction)
 */
struct VRefBuffer
{
  private:
    static struct Chunk
    {
        ubyte[] data;  // storing serialized value
        size_t  used;  // used size of data
    }

    immutable size_t Threshold, ChunkSize;

    // for putCopy
    Chunk[] chunks_;  // memory chunk for buffer
    size_t  index_;   // index for cunrrent chunk

    // for putRef
    iovec[] vecList_;  // referece to large data or copied data.


  public:
    /**
     * Constructs a buffer.
     *
     * Params:
     *  threshold = the threshold of writing value or stores reference.
     *  chunkSize = the default size of chunk for allocation.
     */
    @safe
    this(in size_t threshold = 32, in size_t chunkSize = 8192)
    {
        Threshold = threshold;
        ChunkSize = chunkSize;

        chunks_.length = 1;
        chunks_[index_].data.length = chunkSize;
    }


    /**
     * Returns the buffer contents that excluding references.
     *
     * Returns:
     *  the non-contiguous copied contents.
     */
    @property @safe
    nothrow ubyte[] data()
    {
        ubyte[] result;

        foreach (ref chunk; chunks_)
            result ~= chunk.data[0..chunk.used];

        return result;
    }


    /**
     * Forwards to all buffer contents.
     *
     * Returns:
     *  the array of iovec struct that stores references.
     */
    @property @safe
    nothrow ref iovec[] vector()
    {
        return vecList_;
    }


    /**
     * Writes the argument to buffer and stores the reference of writed content 
     * if the argument size is smaller than threshold,
     * otherwise stores the reference of argument directly.
     *
     * Params:
     *  value = the content to write.
     */
    @safe
    void put(in ubyte value)
    {
        ubyte[1] values = [value];
        putCopy(values);
    }


    /// ditto
    @safe
    void put(in ubyte[] value)
    {
        if (value.length < Threshold)
            putCopy(value);
        else
            putRef(value);
    }


  private:
    /*
     * Stores the reference of $(D_PARAM value).
     *
     * Params:
     *  value = the content to write.
     */
    @trusted
    void putRef(in ubyte[] value)
    {
        vecList_.length += 1;
        vecList_[$ - 1]  = iovec(cast(void*)value.ptr, value.length);
    }


    /*
     * Writes $(D_PARAM value) to buffer and appends to its reference.
     *
     * Params:
     *  value = the contents to write.
     */
    @safe
    void putCopy(in ubyte[] value)
    {
        /*
         * Helper for expanding new space.
         */
        void expand(in size_t size)
        {
            const newSize = size < ChunkSize ? ChunkSize : size;

            index_++;
            chunks_.length = 1;
            chunks_[index_].data.length = newSize;
        }

        const size = value.length;

        // lacks current chunk?
        if (chunks_[index_].data.length - chunks_[index_].used < size)
            expand(size);

        const base = chunks_[index_].used;                     // start index
        auto  data = chunks_[index_].data[base..base + size];  // chunk to write

        data[] = value;
        chunks_[index_].used += size;

        // Optimization for avoiding iovec allocation.
        if (vecList_.length && data.ptr == (vecList_[$ - 1].iov_base +
                                            vecList_[$ - 1].iov_len))
            vecList_[$ - 1].iov_len += size;
        else
            putRef(data);
    }
}


/**
 * Helper for $(D VRefBuffer) construction.
 *
 * Params:
 *  threshold = the threshold of writing value or stores reference.
 *  chunkSize = the default size of chunk for allocation.
 *
 * Returns:
 *  a $(D VRefBuffer) object instantiated and initialized according to the arguments.
 */
@safe
VRefBuffer vrefBuffer(in size_t threshold = 32, in size_t chunkSize = 8192)
{
    return typeof(return)(threshold, chunkSize);
}


unittest
{
    static assert(isOutputRange!(VRefBuffer, ubyte) &&
                  isOutputRange!(VRefBuffer, ubyte[]));

    auto buffer = vrefBuffer(2, 4);

    ubyte[] tests = [1, 2];
    foreach (v; tests)
        buffer.put(v);
    buffer.put(tests);

    assert(buffer.data == tests, "putCopy failed");

    iovec[] vector = buffer.vector;
    ubyte[] result;

    assert(vector.length == 2, "Optimization failed");

    foreach (v; vector)
        result ~= (cast(ubyte*)v.iov_base)[0..v.iov_len];

    assert(result == tests ~ tests);
}


// Serializing routines


/**
 * $(D Packer) is a $(D MessagePack) serializer
 *
 * Example:
 * -----
 * auto packer = packer(Appender!(ubyte[])());
 *
 * packer.packArray(false, 100, 1e-10, null);
 *
 * stdout.rawWrite(packer.buffer.data);
 * -----
 *
 * NOTE:
 *  Current implementation can't deal with a circular reference.
 *  If you try to serialize a object that has circular reference, runtime raises 'Stack Overflow'.
 */
struct Packer(Stream) if (isOutputRange!(Stream, ubyte) && isOutputRange!(Stream, ubyte[]))
{
  private:
    enum size_t Offset = 1;  // type-information offset

    Stream                   stream_;  // the stream to write
    ubyte[Offset + RealSize] store_;   // stores serialized value


  public:
    /**
     * Constructs a packer with $(D_PARAM stream).
     *
     * Params:
     *  stream = the stream to write.
     */
    @safe
    this(Stream stream)
    {
        stream_ = stream;
    }


    /**
     * Forwards to stream.
     *
     * Returns:
     *  the stream.
     */
    @property @safe
    nothrow ref Stream stream()
    {
        return stream_;
    }


    /**
     * Serializes argument and writes to stream.
     *
     * If the argument is the pointer type, dereferences the pointer and serializes pointed value.
     * -----
     * int  a = 10;
     * int* b = &b;
     *
     * packer.pack(b);  // serializes 10, not address of a
     * -----
     * Serializes nil if the argument of nullable type is null.
     *
     * NOTE:
     *  MessagePack doesn't define $(D_KEYWORD real) type format.
     *  Don't serialize $(D_KEYWORD real) if you communicate with other languages.
     *  Transfer $(D_KEYWORD double) serialization if $(D_KEYWORD real) on your environment equals $(D_KEYWORD double).
     *
     * Params:
     *  value = the content to serialize.
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    ref Packer pack(T)(in T value) if (is(Unqual!T == bool))
    {
        if (value)
            stream_.put(Format.TRUE);
        else
            stream_.put(Format.FALSE);

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T value) if (isUnsigned!T)
    {
        // ulong < ulong is slower than uint < uint
        static if (!is(Unqual!T  == ulong)) {
            enum Bits = T.sizeof * 8;

            if (value < (1 << 8)) {
                if (value < (1 << 7)) {
                    // fixnum
                    stream_.put(take8from!Bits(value));
                } else {
                    // uint 8
                    store_[0] = Format.UINT8;
                    store_[1] = take8from!Bits(value);
                    stream_.put(store_[0..Offset + ubyte.sizeof]);
                }
            } else {
                if (value < (1 << 16)) {
                    // uint 16
                    const temp = convertEndianTo!16(value);

                    store_[0] = Format.UINT16;
                    *cast(ushort*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + ushort.sizeof]);
                } else {
                    // uint 32
                    const temp = convertEndianTo!32(value);

                    store_[0] = Format.UINT32;
                    *cast(uint*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + uint.sizeof]);
                }
            }
        } else {
            if (value < (1UL << 8)) {
                if (value < (1UL << 7)) {
                    // fixnum
                    stream_.put(take8from!64(value));
                } else {
                    // uint 8
                    store_[0] = Format.UINT8;
                    store_[1] = take8from!64(value);
                    stream_.put(store_[0..Offset + ubyte.sizeof]);
                }
            } else {
                if (value < (1UL << 16)) {
                    // uint 16
                    const temp = convertEndianTo!16(value);

                    store_[0] = Format.UINT16;
                    *cast(ushort*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + ushort.sizeof]);
                } else if (value < (1UL << 32)){
                    // uint 32
                    const temp = convertEndianTo!32(value);

                    store_[0] = Format.UINT32;
                    *cast(uint*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + uint.sizeof]);
                } else {
                    // uint 64
                    const temp = convertEndianTo!64(value);

                    store_[0] = Format.UINT64;
                    *cast(ulong*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + ulong.sizeof]);
                }
            }
        }

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T value) if (isSigned!T && isIntegral!T)
    {
        // long < long is slower than int < int
        static if (!is(Unqual!T == long)) {
            enum Bits = T.sizeof * 8;

            if (value < -(1 << 5)) {
                if (value < -(1 << 15)) {
                    // int 32
                    const temp = convertEndianTo!32(value);

                    store_[0] = Format.INT32;
                    *cast(int*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + int.sizeof]);
                } else if (value < -(1 << 7)) {
                    // int 16
                    const temp = convertEndianTo!16(value);

                    store_[0] = Format.INT16;
                    *cast(short*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + short.sizeof]);
                } else {
                    // int 8
                    store_[0] = Format.INT8;
                    store_[1] = take8from!Bits(value);
                    stream_.put(store_[0..Offset + byte.sizeof]);
                }
            } else if (value < (1 << 7)) {
                // fixnum
                stream_.put(take8from!Bits(value));
            } else {
                if (value < (1 << 8)) {
                    // uint 8
                    store_[0] = Format.UINT8;
                    store_[1] = take8from!Bits(value);
                    stream_.put(store_[0..Offset + ubyte.sizeof]);
                } else if (value < (1 << 16)) {
                    // uint 16
                    const temp = convertEndianTo!16(value);

                    store_[0] = Format.UINT16;
                    *cast(ushort*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + ushort.sizeof]);
                } else {
                    // uint 32
                    const temp = convertEndianTo!32(value);

                    store_[0] = Format.UINT32;
                    *cast(uint*)&store_[Offset] = temp;
                    stream_.put(store_[0..Offset + uint.sizeof]);
                }
            }
        } else {
            if (value < -(1L << 5)) {
                if (value < -(1L << 15)) {
                    if (value < -(1L << 31)) {
                        // int 64
                        const temp = convertEndianTo!64(value);

                        store_[0] = Format.INT64;
                        *cast(long*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + long.sizeof]);
                    } else {
                        // int 32
                        const temp = convertEndianTo!32(value);

                        store_[0] = Format.INT32;
                        *cast(int*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + int.sizeof]);
                    }
                } else {
                    if (value < -(1L << 7)) {
                        // int 16
                        const temp = convertEndianTo!16(value);

                        store_[0] = Format.INT16;
                        *cast(short*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + short.sizeof]);
                    } else {
                        // int 8
                        store_[0] = Format.INT8;
                        store_[1] = take8from!64(value);
                        stream_.put(store_[0..Offset + byte.sizeof]);
                    }
                }
            } else if (value < (1L << 7)) {
                // fixnum
                stream_.put(take8from!64(value));
            } else {
                if (value < (1L << 16)) {
                    if (value < (1L << 8)) {
                        // uint 8
                        store_[0] = Format.UINT8;
                        store_[1] = take8from!64(value);
                        stream_.put(store_[0..Offset + ubyte.sizeof]);
                    } else {
                        // uint 16
                        const temp = convertEndianTo!16(value);

                        store_[0] = Format.UINT16;
                        *cast(ushort*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + ushort.sizeof]);
                    }
                } else {
                    if (value < (1L << 32)) {
                        // uint 32
                        const temp = convertEndianTo!32(value);

                        store_[0] = Format.UINT32;
                        *cast(uint*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + uint.sizeof]);
                    } else {
                        // uint 64
                        const temp = convertEndianTo!64(value);

                        store_[0] = Format.UINT64;
                        *cast(ulong*)&store_[Offset] = temp;
                        stream_.put(store_[0..Offset + ulong.sizeof]);
                    }
                }
            }
        }

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T value) if (isFloatingPoint!T)
    {
        static if (is(Unqual!T == float)) {
            const temp = convertEndianTo!32(_f(value).i);

            store_[0] = Format.FLOAT;
            *cast(uint*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + uint.sizeof]);
        } else static if (is(Unqual!T == double)) {
            const temp = convertEndianTo!64(_d(value).i);

            store_[0] = Format.DOUBLE;
            *cast(ulong*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + ulong.sizeof]);
        } else {
            static if (real.sizeof > double.sizeof) {
                store_[0]      = Format.REAL;
                const temp     = _r(value);
                const fraction = convertEndianTo!64(temp.fraction);
                const exponent = convertEndianTo!16(temp.exponent);

                *cast(Unqual!(typeof(fraction))*)&store_[Offset]                   = fraction;
                *cast(Unqual!(typeof(exponent))*)&store_[Offset + fraction.sizeof] = exponent;
                stream_.put(store_[0..$]);
            } else {  // Non-x86 CPUs, real type equals double type.
                pack(cast(double)value);
            }
        }

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T value) if (is(Unqual!T == enum))
    {
        pack(cast(OriginalType!T)value);

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T value) if (isPointer!T)
    {
        static if (is(Unqual!T == void*)) {  // for pack(null)
            enforce(value is null, "Can't serialize void type");
            stream_.put(Format.NIL);
        } else {
            if (value is null)
                stream_.put(Format.NIL);
            else
                pack(mixin(AsteriskOf!T ~ "value"));
        }

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T array) if (isArray!T)
    {
        alias typeof(T.init[0]) U;

        /*
         * Serializes raw type-information to stream.
         */
        void beginRaw(in size_t length)
        {
            if (length < 32) {
                const ubyte temp = Format.RAW | cast(ubyte)length;
                stream_.put(take8from(temp));
            } else if (length < 65536) {
                const temp = convertEndianTo!16(length);

                store_[0] = Format.RAW16;
                *cast(ushort*)&store_[Offset] = temp;
                stream_.put(store_[0..Offset + ushort.sizeof]);
            } else {
                const temp = convertEndianTo!32(length);

                store_[0] = Format.RAW32;
                *cast(uint*)&store_[Offset] = temp;
                stream_.put(store_[0..Offset + uint.sizeof]);
            }
        }

        if (array is null)
            return packNil();

        // Raw bytes
        static if (isByte!(U) || isSomeChar!(U)) {
            ubyte[] raw = cast(ubyte[])array;

            beginRaw(raw.length);
            stream_.put(raw);
        } else {
            beginArray(array.length);
            foreach (elem; array)
                pack(elem);
        }

        return this;
    }


    /// ditto
    ref Packer pack(T)(in T array) if (isAssociativeArray!T)
    {
        if (array is null)
            return packNil();

        beginMap(array.length);
        foreach (key, value; array) {
            pack(key);
            pack(value);
        }

        return this;
    }


    /// ditto
    ref Packer pack(Types...)(auto ref Types objects)
    {
        foreach (i, T; Types)
            pack(objects[i]);

        return this;
    }


    /**
     * Serializes $(D_PARAM object) and writes to stream.
     *
     * $(D_KEYWORD struct) and $(D_KEYWORD class) need to implement $(D toMsgpack) method.
     * $(D toMsgpack) signature is:
     * -----
     * void toMsgpack(Packer)(ref Packer packer) const
     * -----
     * Assumes $(D std.typecons.Tuple) if $(D_KEYWORD struct) doens't implement $(D toMsgpack).
     * $(D std.typecons.Tuple) is serialized to Array type.
     * -----
     * packer.pack(tuple(true, 1, "Hi!"))  // -> '[true, 1, "Hi!"]', not 'ture, 1, "Hi!"'
     * -----
     *
     * Params:
     *  object = the content to serialize.
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    ref Packer pack(T)(in T object) if (is(Unqual!T == class))
    {
        static if (!__traits(compiles, { T t; t.toMsgpack(this); }))
            static assert(false, T.stringof ~ " is not a MessagePackable object");

        if (object is null)
            return packNil();

        object.toMsgpack(this);

        return this;
    }


    /// ditto
    ref Packer pack(T)(auto ref T object) if (is(Unqual!T == struct))
    {
        static if (__traits(compiles, { T t; t.toMsgpack(this); })) {
            object.toMsgpack(this);
        } else {  // std.typecons.Tuple
            beginArray(object.field.length);
            foreach (f; object.field)
                pack(f);
        }

        return this;
    }


    /**
     * Serializes the arguments as container to stream.
     *
     * -----
     * packer.packArray(true, 1);  // -> [true, 1]
     * packer.packMap("Hi", 100);  // -> ["Hi":100]
     * -----
     *
     * In packMap, the number of arguments must be even.
     *
     * Params:
     *  objects = the contents to serialize.
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    ref Packer packArray(Types...)(auto ref Types objects)
    {
        beginArray(Types.length);
        foreach (i, T; Types)
            pack(objects[i]);
        // pack(objects);  // slow :(

        return this;
    }


    /// ditto
    ref Packer packMap(Types...)(auto ref Types objects)
    {
        static assert(Types.length % 2 == 1, "The number of arguments must be even");

        beginMap(Types.length / 2);
        foreach (i, T; Types)
            pack(objects[i]);

        return this;
    }


    /**
     * Serializes the type-information to stream.
     *
     * These methods don't serialize contents.
     * You need to call pack method to serialize contents at your own risk.
     * -----
     * packer.beginArray(3).pack(true, 1);  // -> [true, 1,
     *
     * // other operation
     * 
     * packer.pack("Hi!");                  // -> [true, 1, "Hi!"]
     * -----
     *
     * Params:
     *  length = the length of container.
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    ref Packer beginArray(in size_t length)
    {
        if (length < 16) {
            const ubyte temp = Format.ARRAY | cast(ubyte)length;
            stream_.put(take8from(temp));
        } else if (length < 65536) {
            const temp = convertEndianTo!16(length);

            store_[0] = Format.ARRAY16;
            *cast(ushort*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + ushort.sizeof]);
        } else {
            const temp = convertEndianTo!32(length);

            store_[0] = Format.ARRAY32;
            *cast(uint*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + uint.sizeof]);
        }

        return this;
    }


    /// ditto
    ref Packer beginMap(in size_t length)
    {
        if (length < 16) {
            const ubyte temp = Format.MAP | cast(ubyte)length;
            stream_.put(take8from(temp));
        } else if (length < 65536) {
            const temp = convertEndianTo!16(length);

            store_[0] = Format.MAP16;
            *cast(ushort*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + ushort.sizeof]);
        } else {
            const temp = convertEndianTo!32(length);

            store_[0] = Format.MAP32;
            *cast(uint*)&store_[Offset] = temp;
            stream_.put(store_[0..Offset + uint.sizeof]);
        }

        return this;
    }


  private:
    /*
     * Serializes the nil value.
     */
    ref Packer packNil()
    {
        stream_.put(Format.NIL);
        return this;
    }
}


/**
 * Helper for $(D Packer) construction.
 *
 * Params:
 *  stream = the stream to write.
 *
 * Returns:
 *  a $(D Packer) object instantiated and initialized according to the arguments.
 */
@safe
Packer!(Stream) packer(Stream)(Stream stream)
{
    return typeof(return)(stream);
}


version (unittest) 
{
    alias Appender!(ubyte[]) SimpleBuffer;

    mixin template DefinePacker()
    {
        SimpleBuffer buffer; Packer!(SimpleBuffer*) packer = packer(&buffer);
    }
}

unittest
{
    { // unique value
        mixin DefinePacker;

        ubyte[] result = [Format.NIL, Format.TRUE, Format.FALSE];

        packer.pack(null, true, false);
        foreach (i, value; packer.stream.data)
            assert(value == result[i]);
    }
    { // uint *
        static struct UTest { ubyte format; ulong value; }

        enum : ulong { A = ubyte.max, B = ushort.max, C = uint.max, D = ulong.max }

        static UTest[][] tests = [
            [{Format.UINT8, A}], 
            [{Format.UINT8, A}, {Format.UINT16, B}],
            [{Format.UINT8, A}, {Format.UINT16, B}, {Format.UINT32, C}],
            [{Format.UINT8, A}, {Format.UINT16, B}, {Format.UINT32, C}, {Format.UINT64, D}],
        ];

        foreach (I, T; TypeTuple!(ubyte, ushort, uint, ulong)) {
            foreach (i, test; tests[I]) {
                mixin DefinePacker;

                packer.pack(cast(T)test.value);
                assert(buffer.data[0] == test.format);

                switch (i) {
                case 0:
                    auto answer = take8from!(T.sizeof * 8)(test.value);
                    assert(memcmp(&buffer.data[1], &answer, ubyte.sizeof) == 0);
                    break;
                case 1:
                    auto answer = convertEndianTo!16(test.value);
                    assert(memcmp(&buffer.data[1], &answer, ushort.sizeof) == 0);
                    break;
                case 2:
                    auto answer = convertEndianTo!32(test.value);
                    assert(memcmp(&buffer.data[1], &answer, uint.sizeof) == 0);
                    break;
                default:
                    auto answer = convertEndianTo!64(test.value);
                    assert(memcmp(&buffer.data[1], &answer, ulong.sizeof) == 0);
                }
            }
        }
    }
    { // int *
        static struct STest { ubyte format; long value; }

        enum : long { A = byte.min, B = short.min, C = int.min, D = long.min }

        static STest[][] tests = [
            [{Format.INT8, A}], 
            [{Format.INT8, A}, {Format.INT16, B}],
            [{Format.INT8, A}, {Format.INT16, B}, {Format.INT32, C}],
            [{Format.INT8, A}, {Format.INT16, B}, {Format.INT32, C}, {Format.INT64, D}],
        ];

        foreach (I, T; TypeTuple!(byte, short, int, long)) {
            foreach (i, test; tests[I]) {
                mixin DefinePacker;

                packer.pack(cast(T)test.value);
                assert(buffer.data[0] == test.format);

                switch (i) {
                case 0:
                    auto answer = take8from!(T.sizeof * 8)(test.value);
                    assert(memcmp(&buffer.data[1], &answer, byte.sizeof) == 0);
                    break;
                case 1:
                    auto answer = convertEndianTo!16(test.value);
                    assert(memcmp(&buffer.data[1], &answer, short.sizeof) == 0);
                    break;
                case 2:
                    auto answer = convertEndianTo!32(test.value);
                    assert(memcmp(&buffer.data[1], &answer, int.sizeof) == 0);
                    break;
                default:
                    auto answer = convertEndianTo!64(test.value);
                    assert(memcmp(&buffer.data[1], &answer, long.sizeof) == 0);
                }
            }
        }
    }
    { // fload, double
        static if (real.sizeof == double.sizeof)
            alias TypeTuple!(float, double, double) FloatingTypes;
        else
            alias TypeTuple!(float, double, real) FloatingTypes;

        static struct FTest { ubyte format; real value; }

        static FTest[] tests = [
            {Format.FLOAT,  float.min},
            {Format.DOUBLE, double.max},
            {Format.REAL,   real.max},
        ];

        foreach (I, T; FloatingTypes) {
            mixin DefinePacker;

            packer.pack(cast(T)tests[I].value);
            assert(buffer.data[0] == tests[I].format);

            switch (I) {
            case 0:
                const answer = convertEndianTo!32(_f(cast(T)tests[I].value).i);
                assert(memcmp(&buffer.data[1], &answer, float.sizeof) == 0);
                break;
            case 1:
                const answer = convertEndianTo!64(_d(cast(T)tests[I].value).i);
                assert(memcmp(&buffer.data[1], &answer, double.sizeof) == 0);
                break;
            default:
                const t = _r(cast(T)tests[I].value);
                const f = convertEndianTo!64(t.fraction);
                const e = convertEndianTo!16(t.exponent);
                assert(memcmp(&buffer.data[1],            &f, f.sizeof) == 0);
                assert(memcmp(&buffer.data[1 + f.sizeof], &e, e.sizeof) == 0);
            }
        }
    }
    { // pointer
        static struct PTest
        { 
            ubyte format; 

            union
            {
                ulong*  p0;
                long*   p1;
                double* p2;
            }
        }

        PTest[] tests = [PTest(Format.UINT64), PTest(Format.INT64), PTest(Format.DOUBLE)];

        ulong  v0 = ulong.max;
        long   v1 = long.min;
        double v2 = double.max;

        foreach (I, Index; TypeTuple!("0", "1", "2")) {
            mixin DefinePacker;

            mixin("tests[I].p" ~ Index ~ " = &v" ~ Index ~ ";");

            packer.pack(mixin("tests[I].p" ~ Index));
            assert(buffer.data[0] == tests[I].format);

            switch (I) {
            case 0:
                auto answer = convertEndianTo!64(*tests[I].p0);
                assert(memcmp(&buffer.data[1], &answer, ulong.sizeof) == 0);
                break;
            case 1:
                auto answer = convertEndianTo!64(*tests[I].p1);
                assert(memcmp(&buffer.data[1], &answer, long.sizeof) == 0);
                break;
            default:
                const answer = convertEndianTo!64(_d(*tests[I].p2).i);
                assert(memcmp(&buffer.data[1], &answer, double.sizeof) == 0);
            }
        }
    }
    { // enum
        enum E : ubyte { A = ubyte.max }

        mixin DefinePacker; E e = E.A;

        packer.pack(e);
        assert(buffer.data[0] == Format.UINT8);

        auto answer = E.A;
        assert(memcmp(&buffer.data[1], &answer, (OriginalType!E).sizeof) == 0);
    }
    { // container
        static struct Test { ubyte format; size_t value; }

        enum : ulong { A = 16 / 2, B = ushort.max, C = uint.max }

        static Test[][] tests = [
            [{Format.ARRAY | A, Format.ARRAY | A}, {Format.ARRAY16, B}, {Format.ARRAY32, C}],
            [{Format.MAP   | A, Format.MAP   | A}, {Format.MAP16,   B}, {Format.MAP32,   C}],
        ];

        foreach (I, Name; TypeTuple!("Array", "Map")) {
            auto test = tests[I];

            foreach (i, T; TypeTuple!(ubyte, ushort, uint)) {
                mixin DefinePacker; 
                mixin("packer.begin" ~ Name ~ "(i ? test[i].value : A);");

                assert(buffer.data[0] == test[i].format);

                switch (i) {
                case 0:
                    auto answer = take8from(test[i].value);
                    assert(memcmp(&buffer.data[0], &answer, ubyte.sizeof) == 0);
                    break;
                case 1:
                    auto answer = convertEndianTo!16(test[i].value);
                    assert(memcmp(&buffer.data[1], &answer, ushort.sizeof) == 0);
                    break;
                default:
                    auto answer = convertEndianTo!32(test[i].value);
                    assert(memcmp(&buffer.data[1], &answer, uint.sizeof) == 0);
                }
            }
        }
    }
    { // user defined
        {
            static struct S
            {
                uint num = uint.max;

                void toMsgpack(P)(ref P p) const { p.packArray(num); }
            }

            mixin DefinePacker; S test;

            packer.pack(test);

            assert(buffer.data[0] == (Format.ARRAY | 1));
            assert(buffer.data[1] ==  Format.UINT32);
            assert(memcmp(&buffer.data[2], &test.num, uint.sizeof) == 0);
        }
        {
            mixin DefinePacker; auto test = tuple(true, false, uint.max);

            packer.pack(test);

            assert(buffer.data[0] == (Format.ARRAY | 3));
            assert(buffer.data[1] ==  Format.TRUE);
            assert(buffer.data[2] ==  Format.FALSE);
            assert(buffer.data[3] ==  Format.UINT32);
            assert(memcmp(&buffer.data[4], &test.field[2], uint.sizeof) == 0);
        }
        {
            static class C
            {
                uint num;

                this(uint n) { num = n; }

                void toMsgpack(P)(ref P p) const { p.packArray(num); }
            }

            mixin DefinePacker; C test = new C(ushort.max);

            packer.pack(test);

            assert(buffer.data[0] == (Format.ARRAY | 1));
            assert(buffer.data[1] ==  Format.UINT16);
            assert(memcmp(&buffer.data[2], &test.num, ushort.sizeof) == 0);
        }
    }
}


// deserializing routines


/**
 * $(D UnpackException) is thrown on parse error
 */
class UnpackException : Exception
{
    this(string message)
    { 
        super(message);
    }
}


/**
 * $(D InvalidTypeException) is thrown on type errors
 */
class InvalidTypeException : Exception
{
    this(string message)
    {
        super(message);
    }
}


version (D_Ddoc)
{
    /**
     * Internal buffer and related operations for Unpacker
     *
     * Following Unpackers mixin this template. So, Unpacker can use following methods.
     *
     * -----
     * //buffer image:
     * +-------------------------------------------+
     * | [object] | [obj | unparsed... | unused... |
     * +-------------------------------------------+
     *            ^ offset
     *                   ^ current
     *                                 ^ used
     *                                             ^ buffer.length
     * -----
     *
     * This mixin template is a private.
     */
    mixin template InternalBuffer()
    {
        /**
         * Forwards to internal buffer.
         *
         * Returns:
         *  the reference of internal buffer.
         */
        @property @safe
        nothrow ubyte[] buffer();


        /**
         * Fills internal buffer with $(D_PARAM target).
         *
         * Params:
         *  target = new serialized buffer to deserialize.
         */
        /* @safe */ void feed(in ubyte[] target);


        /**
         * Consumes buffer. This method is helper for buffer property.
         * You must use this method if you write bytes to buffer directly.
         *
         * Params:
         *  size = the number of consuming.
         */
        @safe
        nothrow void bufferConsumed(in size_t size);


        /**
         * Removes unparsed buffer.
         */
        @safe
        nothrow void removeUnparsed();


        /**
         * Returns:
         *  the total size including unparsed buffer size.
         */
        @property @safe
        nothrow size_t size() const;


        /**
         * Returns:
         *  the parsed size of buffer.
         */
        @property @safe
        nothrow size_t parsedSize() const;


        /**
         * Returns:
         *  the unparsed size of buffer.
         */
        @property @safe
        nothrow size_t unparsedSize() const;
    }
}
else
{ 
    private mixin template InternalBuffer()
    {
      private:
        ubyte[] buffer_;  // internal buffer
        size_t  used_;    // index that buffer cosumed
        size_t  offset_;  // index that buffer parsed
        size_t  parsed_;  // total size of parsed message
        bool    hasRaw_;  // indicates whether Raw object has been deserialized


      public:
        @property @safe
        nothrow ubyte[] buffer()
        {
            return buffer_;
        }


        /* @safe */ void feed(in ubyte[] target)
        in
        {
            assert(target.length);
        }
        body
        {
            /*
             * Expands internal buffer.
             *
             * Params:
             *  size = new buffer size to append.
             */
            void expandBuffer(in size_t size)
            {
                // rewinds buffer(completed deserialization)
                if (used_ == offset_ && !hasRaw_) {
                    used_ =  offset_ = 0;

                    if (buffer_.length < size)
                        buffer_.length = size;

                    return;
                }

                // deserializing state is mid-flow(buffer has non-parsed data yet)
                auto unparsed = buffer_[offset_..used_];
                auto restSize = buffer_.length - used_ + offset_;
                auto newSize  = size > restSize ? unparsedSize + size : buffer_.length;

                if (hasRaw_) {
                    hasRaw_ = false;
                    buffer_ = new ubyte[](newSize);
                } else {
                    buffer_.length = newSize;

                    // avoids overlapping copy
                    auto area = buffer_[0..unparsedSize];
                    unparsed  = area.overlap(unparsed) ? unparsed.dup : unparsed;
                }

                buffer_[0..unparsedSize] = unparsed;
                used_   = unparsedSize;
                offset_ = 0;
            }

            const size = target.length;

            // lacks current buffer?
            if (buffer_.length - used_ < size)
                expandBuffer(size);

            buffer_[used_..used_ + size] = target;
            used_ += size;
        }


        @safe
        nothrow void bufferConsumed(in size_t size)
        {
            if (used_ + size > buffer_.length)
                used_ = buffer_.length;
            else
                used_ += size;
        }


        @safe
        nothrow void removeUnparsed()
        {
            used_ = offset_;
        }


        @property @safe
        nothrow size_t size() const
        {
            return parsed_ - offset_ + used_;
        }


        @property @safe
        nothrow size_t parsedSize() const
        {
            return parsed_;
        }


        @property @safe
        nothrow size_t unparsedSize() const
        {
            return used_ - offset_;
        }


      private:
        @safe
        void initializeBuffer(in ubyte[] target, in size_t bufferSize = 8192)
        {
            const size = target.length;

            buffer_ = new ubyte[](size > bufferSize ? size : bufferSize); 
            used_   = size;
            buffer_[0..size] = target;
        }
    }
}


/**
 * Implementation types for template specialization
 */
enum UnpackerType
{
    direct,  /// Direct-conversion deserializer
    stream   /// Stream deserializer
}


/**
 * This $(D Unpacker) is a $(D MessagePack) direct-conversion deserializer
 *
 * This implementation is suitable for fixed data.
 *
 * Example:
 * -----
 * // serializedData is [10, 0.1, false]
 * auto unpacker = unpacker!(UnpackerType.direct)(serializedData);
 *
 * uint   n;
 * double d;
 * bool   b;
 *
 * unpacker.unpackArray(n, d, b);
 *
 * // using Tuple
 * Tuple!(uint, double, bool) record;
 * unpacker.unpack(record);  // record is [10, 0.1, false]
 * -----
 */
struct Unpacker(UnpackerType Type : UnpackerType.direct)
{
  private:
    enum Offset = 1;

    mixin InternalBuffer;


  public:
    /**
     * Constructs a $(D Unpacker).
     *
     * Params:
     *  target     = byte buffer to deserialize
     *  bufferSize = size limit of buffer size
     */
    @safe
    this(in ubyte[] target, in size_t bufferSize = 8192)
    {
        initializeBuffer(target, bufferSize);
    }


    /**
     * Clears states for next deserialization.
     */
    @safe
    nothrow void clear()
    {
        parsed_ = 0;
    }


    /**
     * Deserializes $(D_PARAM T) object and assigns to $(D_PARAM value).
     *
     * If the argument is pointer, dereferences pointer and assigns deserialized value.
     * -----
     * int* a;
     * unpacker.unpack(a)  // enforce throws Exception because a is null or
     *                     // no throw if deserialized value is nil
     *
     * int b; a = &b;
     * unpacker.unpack(b)  // b is deserialized value or
     *                     // assigns null if deserialized value is nil
     * -----
     * 
     * Params:
     *  value = the reference of value to assign.
     *
     * Returns:
     *  self, i.e. for method chaining.
     *
     * Throws:
     *  UnpackException when doesn't read from buffer or precision loss occurs and
     *  InvalidTypeException when $(D_PARAM T) type doesn't match serialized type.
     */
    ref Unpacker unpack(T)(ref T value) if (is(Unqual!T == bool))
    {
        canRead(Offset, 0);
        const header = read();

        switch (header) {
        case Format.TRUE:
            value = true;
            break;
        case Format.FALSE:
            value = false;
            break;
        default:
            rollback();
        }

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(ref T value) if (isUnsigned!T)
    {
        canRead(Offset, 0);
        const header = read();

        if (0x00 <= header && header <= 0x7f) {
            value = header;
        } else {
            switch (header) {
            case Format.UINT8:
                canRead(ubyte.sizeof);
                value = read();
                break;
            case Format.UINT16:
                canRead(ushort.sizeof);
                auto us = load16To!ushort(read(ushort.sizeof));
                if (us > T.max)
                    rollback(ushort.sizeof);
                value = cast(T)us;
                break;
            case Format.UINT32:
                canRead(uint.sizeof);
                auto ui = load32To!uint(read(uint.sizeof));
                if (ui > T.max)
                    rollback(uint.sizeof);
                value = cast(T)ui;
                break;
            case Format.UINT64:
                canRead(ulong.sizeof);
                auto ul = load64To!ulong(read(ulong.sizeof));
                if (ul > T.max)
                    rollback(ulong.sizeof);
                value = cast(T)ul;
                break;
            default:
                rollback();
            }
        }

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(ref T value) if (isSigned!T && isIntegral!T)
    {
        canRead(Offset, 0);
        const header = read();

        if ((0x00 <= header && header <= 0x7f) || (0xe0 <= header && header <= 0xff)) {
            value = cast(T)header;
        } else {
            switch (header) {
            case Format.UINT8:
                canRead(ubyte.sizeof);
                auto ub = read();
                if (ub > T.max)
                    rollback(ubyte.sizeof);
                value = cast(T)ub;
                break;
            case Format.UINT16:
                canRead(ushort.sizeof);
                auto us = load16To!ushort(read(ushort.sizeof));
                if (us > T.max)
                    rollback(ushort.sizeof);
                value = cast(T)us;
                break;
            case Format.UINT32:
                canRead(uint.sizeof);
                auto ui = load32To!uint(read(uint.sizeof));
                if (ui > T.max)
                    rollback(uint.sizeof);
                value = cast(T)ui;
                break;
            case Format.UINT64:
                canRead(ulong.sizeof);
                auto ul = load64To!ulong(read(ulong.sizeof));
                if (ul > T.max)
                    rollback(ulong.sizeof);
                value = cast(T)ul;
                break;
            case Format.INT8:
                canRead(byte.sizeof);
                value = cast(byte)read();
                break;
            case Format.INT16:
                canRead(short.sizeof);
                auto s = load16To!short(read(short.sizeof));
                if (s < T.min || T.max < s)
                    rollback(short.sizeof);
                value = cast(T)s;
                break;
            case Format.INT32:
                canRead(int.sizeof);
                auto i = load32To!int(read(int.sizeof));
                if (i < T.min || T.max < i)
                    rollback(int.sizeof);
                value = cast(T)i;
                break;
            case Format.INT64:
                canRead(long.sizeof);
                auto l = load64To!long(read(long.sizeof));
                if (l < T.min || T.max < l)
                    rollback(long.sizeof);
                value = cast(T)l;
                break;
            default:
                rollback();
            }
        }

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(ref T value) if (isFloatingPoint!T)
    {
        canRead(Offset, 0);
        const header = read();

        switch (header) {
        case Format.FLOAT:
            _f temp;

            canRead(uint.sizeof);
            temp.i = load32To!uint(read(uint.sizeof));
            value  = temp.f;
            break;
        case Format.DOUBLE:
            // check precision loss
            static if (is(Unqual!T == float))
                rollback();

            _d temp;

            canRead(ulong.sizeof);
            temp.i = load64To!ulong(read(ulong.sizeof));
            value  = temp.f;
            break;
        case Format.REAL:
            // check precision loss
            static if (is(Unqual!T == float) || is(Unqual!T == double))
                rollback();

            canRead(RealSize);

            version (NonX86)
            {
                CustomFloat!80 temp;

                const frac = load64To!ulong (read(ulong.sizeof));
                const exp  = load16To!ushort(read(ushort.sizeof));

                temp.significand = frac;
                temp.exponent    = exp & 0x7fff;
                temp.sign        = exp & 0x8000 ? true : false;

                // NOTE: temp.get!real is inf on non-x86 when deserialized value is larger than double.max.
                value = temp.get!real;
            }
            else
            {
                _r temp;

                temp.fraction = load64To!(typeof(temp.fraction))(read(temp.fraction.sizeof));
                temp.exponent = load16To!(typeof(temp.exponent))(read(temp.exponent.sizeof));

                value = temp.f;
            }

            break;
        default:
            rollback();
        }

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(ref T value) if (is(Unqual!T == enum))
    {
        OriginalType!T temp;

        unpack(temp);

        value = cast(T)temp;

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(T value) if (isPointer!T)
    {
        static if (is(Unqual!T == void*)) {
            enforce(value !is null,  "Can't deserialize void type");
            unpackNil(value);
        } else {
            if (checkNil())
                unpackNil(value);
            else
                enforce(value !is null, T.stringof ~ " is null pointer");

            unpack(mixin(AsteriskOf!T ~ "value"));
        }

        return this;
    }


    /// ditto
    template unpack(Types...) if (Types.length > 1)  // needs constraint-if because "--- killed by signal 11" occurs
    {
        ref Unpacker unpack(ref Types objects)
        {
            foreach (i, T; Types)
                unpack!(T)(objects[i]);

            return this;
        }
    }
    /*
     * @@@BUG@@@ http://d.puremagic.com/issues/show_bug.cgi?id=2460
    ref Unpacker unpack(Types...)(ref Types objects) if (Types.length > 1)
    { // do stuff }
     */


    /**
     * Deserializes $(D_PARAM T) object and assigns to $(D_PARAM array).
     *
     * This is convenient method for array deserialization.
     * Rollback will be completely successful if you deserialize raw type((u)byte[] or string types).
     * But, Rollback will be one element(e.g. int) if you deserialize other types(e.g. int[], int[int])
     *
     * No assign if the length of deserialized object is 0.
     *
     * In a static array, this method checks the length. Do rollback and throw exception
     * if length of $(D_PARAM array) is different from length of deserialized object.
     *
     * Params:
     *  array = the reference of array to assign.
     *
     * Returns:
     *  self, i.e. for method chaining.
     *
     * Throws:
     *  UnpackException when doesn't read from buffer or precision loss occurs and
     *  InvalidTypeException when $(D_PARAM T) type doesn't match serialized type.
     */
    ref Unpacker unpack(T)(ref T array) if (isArray!T)
    {
        alias typeof(T.init[0]) U;

        /*
         * Deserializes type-information of raw type.
         */
        @safe
        size_t beginRaw()
        {
            canRead(Offset, 0);
            const  header = read();
            size_t length;

            if (0xa0 <= header && header <= 0xbf) {
                length = header & 0x1f;
            } else {
                switch (header) {
                case Format.RAW16:
                    canRead(ushort.sizeof);
                    length = load16To!size_t(read(ushort.sizeof));
                    break;
                case Format.RAW32:
                    canRead(uint.sizeof);
                    length = load32To!size_t(read(uint.sizeof));
                    break;
                case Format.NIL:
                    break;
                default:
                    rollback();
                }
            }

            return length;
        }


        if (checkNil())
            return unpackNil(array);

        // Raw bytes
        static if (isByte!U || isSomeChar!U) {
            auto length = beginRaw();
            auto offset = calculateSize!(true)(length);
            if (length == 0)
                return this;

            static if (isStaticArray!T) {
                if (length != array.length)
                    rollback(offset);
            }

            canRead(length, offset + Offset);
            array = cast(T)read(length);

            static if (isDynamicArray!T)
                hasRaw_ = true;
        } else {
            auto length = beginArray();
            if (length == 0)
                return this;

            static if (isStaticArray!T) {
                if (length != array.length)
                    rollback(calculateSize(length));
            } else {
                array.length = length;
            }

            foreach (i; 0..length)
                unpack(array[i]);
        }

        return this;
    }


    /// ditto
    ref Unpacker unpack(T)(ref T array) if (isAssociativeArray!T)
    {
        alias typeof(T.init.keys[0])   K;
        alias typeof(T.init.values[0]) V;

        if (checkNil())
            return unpackNil(array);

        auto length = beginMap();
        if (length == 0)
            return this;

        foreach (i; 0..length) {
            K k; unpack(k);
            V v; unpack(v);
            array[k] = v;
        }

        return this;
    }


    /**
     * Deserializes $(D_PARAM T) object and assigns to $(D_PARAM object).
     *
     * $(D_KEYWORD struct) and $(D_KEYWORD class) need to implement $(D fromMsgpack) method.
     * $(D fromMsgpack) signature is:
     * -----
     * void fromMsgpack(ref Unpacker unpacker)
     * -----
     * Assumes $(D std.typecons.Tuple) if $(D_KEYWORD struct) doens't implement $(D fromMsgpack).
     * Checks length if $(D_PARAM T) is a $(D std.typecons.Tuple).
     *
     * Params:
     *  object = the reference of object to assign.
     *  args   = the arguments to class constructor(class only).
     *           This is used at new statement if $(D_PARAM object) is $(D_KEYWORD null).
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    template unpack(T, Args...) if (is(Unqual!T == class))
    {
        ref Unpacker unpack(ref T object, auto ref Args args)
        {
            static if (!__traits(compiles, { T t; t.fromMsgpack(this); }))
                static assert(false, T.stringof ~ " is not a MessagePackable object");

            if (checkNil())
                return unpackNil(object);

            if (object is null)
                object = new T(args);

            object.fromMsgpack(this);

            return this;
        }
    }
    /*
     * @@@BUG@@@ http://d.puremagic.com/issues/show_bug.cgi?id=2460
    ref Unpacker unpack(T, Args...)(ref T object, auto ref Args args) if (is(Unqual!T == class))
    { // do stuff }
    */


    /// ditto
    ref Unpacker unpack(T)(ref T object) if (is(Unqual!T == struct))
    {
        static if (__traits(compiles, { T t; t.fromMsgpack(this); })) {
            object.fromMsgpack(this);
        } else {
            auto length = beginArray();
            if (length == 0)
                return this;

            if (length != T.Types.length)
                rollback(calculateSize(length));

            foreach (i, Type; T.Types)
                unpack(object.field[i]);
        }

        return this;
    }


    /**
     * Deserializes the container object and assigns to each argument.
     *
     * These methods check the length. Do rollback if
     * the length of arguments is different from length of deserialized object.
     *
     * In unpackMap, the number of arguments must be even.
     *
     * Params:
     *  objects = the references of object to assign.
     *
     * Returns:
     *  self, i.e. for method chaining.
     */
    ref Unpacker unpackArray(Types...)(ref Types objects)
    {
        auto length = beginArray();
        if (length != Types.length)
            rollback(calculateSize(length));

        foreach (i, T; Types)
            unpack(objects[i]);
        // unpack(objects);  // slow :(

        return this;
    }


    /// ditto
    ref Unpacker unpackMap(Types...)(ref Types objects)
    {
        static assert(Types.length % 2 == 1, "The number of arguments must be even");

        auto length = beginMap();
        if (length != Types.length / 2)
            rollback(calculateSize(length));

        foreach (i, T; Types)
            unpack(objects[i]);

        return this;
    }


    /**
     * Deserializes the type-information of container.
     *
     * These methods don't deserialize contents.
     * You need to call unpack method to deserialize contents at your own risk.
     * -----
     * // serialized data is [1, "Hi!"];
     * int num;
     * unpacker.beginArray(2).unpack(num);  // num is 1
     *
     * // other operation
     *
     * string str;
     * unpacker.unpack(str);  // str is "Hi!"
     * -----
     *
     * Returns:
     *  the container size.
     */
    @safe
    size_t beginArray()
    {
        canRead(Offset, 0);
        const  header = read();
        size_t length;

        if (0x90 <= header && header <= 0x9f) {
            length = header & 0x0f;
        } else {
            switch (header) {
            case Format.ARRAY16:
                canRead(ushort.sizeof);
                length = load16To!size_t(read(ushort.sizeof));
                break;
            case Format.ARRAY32:
                canRead(uint.sizeof);
                length = load32To!size_t(read(uint.sizeof));
                break;
            case Format.NIL:
                break;
            default:
                rollback();
            }
        }

        return length;
    }


    /// ditto
    @safe
    size_t beginMap()
    {
        canRead(Offset, 0);
        const  header = read();
        size_t length;

        if (0x80 <= header && header <= 0x8f) {
            length = header & 0x0f;
        } else {
            switch (header) {
            case Format.MAP16:
                canRead(ushort.sizeof);
                length = load16To!size_t(read(ushort.sizeof));
                break;
            case Format.MAP32:
                canRead(uint.sizeof);
                length = load32To!size_t(read(uint.sizeof));
                break;
            case Format.NIL:
                break;
            default:
                rollback();
            }
        }

        return length;
    }


    /**
     * Scans an entire buffer and converts each objects.
     *
     * This method is used for unpacking record-like objects.
     *
     * Example:
     * -----
     * // serialized data is "[1, 2][3, 4][5, 6][...".
     * auto unpacker = unpacker!(UnpackerType.direct)(serializedData);
     * foreach (n, d; &unpacker.scan!(int, int))  // == "foreach (int n, int d; unpacker)"
     *     writeln(n, d); // 1st loop "1, 2", 2nd loop "3, 4"...
     * -----
     */
    int scan(Types...)(scope int delegate(ref Types) dg)
    {
        return opApply!(Types)(delegate int(ref Types objects) { return dg(objects); });
    }


    /// ditto
    int opApply(Types...)(scope int delegate(ref Types) dg)
    {
        int result;

        while (used_ - offset_) {
            auto length = beginArray();
            if (length != Types.length)
                rollback(calculateSize(length));

            Types objects;
            foreach (i, T; Types)
                unpack(objects[i]);

            result = dg(objects);
            if (result)
                return result;
        }

        return result;
    }


  private:
    /*
     * Deserializes nil object and assigns to $(D_PARAM value).
     *
     * Params:
     *  value = the reference of value to assign.
     *
     * Returns:
     *  self, i.e. for method chaining.
     *
     * Throws:
     *  UnpackException when doesn't read from buffer or precision loss occurs and
     *  InvalidTypeException when $(D_PARAM T) type doesn't match serialized type.
     */
    @safe
    ref Unpacker unpackNil(T)(ref T value)
    {
        canRead(Offset, 0);
        const header = read();

        if (header == Format.NIL)
            value = null;
        else
            rollback();

        return this;
    }


    /*
     * Next object is nil?
     *
     * Returns:
     *  true if next object is nil.
     */
    @safe
    bool checkNil()
    {
        canRead(Offset, 0);

        return buffer_[offset_] == Format.NIL;
    }


    /*
     * Calculates the format size of container length.
     */
    size_t calculateSize(bool rawType = false)(in size_t length)
    {
        static if (rawType)
            return length < 32 ? 0 : length < 65536 ? ushort.sizeof : uint.sizeof;
        else
            return length < 16 ? 0 : length < 65536 ? ushort.sizeof : uint.sizeof;
    }


    /*
     * Reading test.
     *
     * Params:
     *  size   = the size to read.
     *  offset = the offset to subtract when doesn't read from buffer.
     *
     * Throws:
     *  UnpackException when doesn't read from buffer.
     */
    @safe
    void canRead(in size_t size, in size_t offset = Offset)
    {
        if (used_ - offset_ < size) {
            if (offset)
                offset_ -= offset;

            throw new UnpackException("Insufficient buffer");
        }
    }


    /*
     * Reads value from buffer and advances offset.
     */
    @safe
    nothrow ubyte read()
    {
        return buffer_[offset_++];
    }


    /*
     * Reads value from buffer and advances offset.
     */
    @safe
    nothrow ubyte[] read(in size_t size)
    {
        auto result = buffer_[offset_..offset_ + size];

        offset_ += size;

        return result;
    }


    /*
     * Do rollback and throws exception.
     */
    @safe
    void rollback(in size_t size = 0)
    {
        offset_ -= size + Offset;
        onInvalidType();
    }
}


unittest
{
    { // unique
        mixin DefinePacker;

        Tuple!(bool, bool) result, test = tuple(true, false);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        assert(test == result);
    }
    { // uint *
        mixin DefinePacker;

        Tuple!(ubyte, ushort, uint, ulong) result,
            test = tuple(cast(ubyte)ubyte.max, cast(ushort)ushort.max,
                         cast(uint)uint.max,   cast(ulong)ulong.max);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        assert(test == result);
    }
    { // int *
        mixin DefinePacker;

        Tuple!(byte, short, int, long) result,
            test = tuple(cast(byte)byte.min, cast(short)short.min,
                         cast(int)int.min,   cast(long)long.min);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        assert(test == result);
    }
    { // floating point
        mixin DefinePacker;

        static if (real.sizeof == double.sizeof)
            Tuple!(float, double, double) result,
                test = tuple(cast(float)float.min, cast(double)double.max, cast(real)real.min);
        else
            Tuple!(float, double, real) result,
                test = tuple(cast(float)float.min, cast(double)double.max, cast(real)real.min);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        assert(test == result);
    }
    { // pointer
        mixin DefinePacker;

        Tuple!(ulong, long, double) origin, values = tuple(ulong.max, long.min, double.min);
        Tuple!(ulong*, long*, double*) 
            result = tuple(&origin.field[0], &origin.field[1], &origin.field[2]),
            test   = tuple(&values.field[0], &values.field[1], &values.field[2]);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        foreach (i, v; test.field)
            assert(*v == *result.field[i]);
        assert(origin == values);
    }
    { // enum
        enum   : float { D = 0.5 }
        enum E : ulong { U = 100 }

        mixin DefinePacker;

        float f = D,   resultF;
        E     e = E.U, resultE;

        packer.pack(D, e);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(resultF, resultE);

        assert(f == resultF);
        assert(e == resultE);
    }
    { // container
        mixin DefinePacker;

        Tuple!(ulong[], double[uint], string, bool[2]) result,
            test = tuple([1UL, 2], [3U:4.0, 5:6.0, 7:8.0],
                         "MessagePack is nice!", [true, false]);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
        unpacker.unpack(result);

        assert(test == result);
    }
    { // user defined
        {
            static struct S
            {
                uint num;

                void toMsgpack(P)(ref P p) const { p.packArray(num); }
                void fromMsgpack(ref Unpacker!(UnpackerType.direct) u)
                { 
                    assert(u.beginArray() == 1);
                    u.unpack(num);
                }
            }

            mixin DefinePacker; S result, test = S(uint.max);

            packer.pack(test);

            auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
            unpacker.unpack(result);

            assert(test.num == result.num);
        }
        {
            static class C
            {
                uint num;

                this(uint n) { num = n; }

                void toMsgpack(P)(ref P p) const { p.packArray(num - 1); }
                void fromMsgpack(ref Unpacker!(UnpackerType.direct) u)
                {
                    assert(u.beginArray() == 1);
                    u.unpack(num);
                }
            }

            mixin DefinePacker; C result, test = new C(ushort.max);

            packer.pack(test);

            auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);
            unpacker.unpack(result, ushort.max);

            assert(test.num == result.num + 1);
        }
    }
    { // variadic
        mixin DefinePacker;

        Tuple!(uint, long, double) test = tuple(uint.max, long.min, double.max);

        packer.pack(test);

        auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);

        uint u; long l; double d;

        unpacker.unpackArray(u, l, d);

        assert(test == tuple(u, l, d));
    }
    { // scan / opApply
        ubyte[] data;

        foreach (i; 0..2) {
            mixin DefinePacker;
            packer.pack(tuple(1, 0.5, "Hi!"));
            data ~= packer.stream.data;
        }

        foreach (n, d, s; &unpacker!(UnpackerType.direct)(data).scan!(int, double, string)) {
            assert(n == 1);
            assert(d == 0.5);
            assert(s == "Hi!");
        }
    }
}


// Static resolution routines for Stream deserializer


/**
 * $(D MessagePack) object type
 */
enum MPType
{
    nil,       /// nil(null in D)
    boolean,   /// true, false
    unsigned,  /// positive fixnum, uint 8, uint 16, uint 32, uint 64
    signed,    /// negative fixnum, int 8, int 16, int 32, int 64
    floating,  /// float, double, real
    array,     /// fix array, array 16, array 32
    map,       /// fix map, map 16, map 32
    raw        /// fix raw, raw 16, raw 32
}


/**
 * $(D MPObject) is a $(D MessagePack) object representation
 *
 * Example:
 * -----
 * auto unpacker = unpacker(pack(1, 0.1L) ~ pack(true) ~ pack("foobarbaz"));
 *
 * foreach (unpacked; unpacker) {
 *     if (unpacked.type == MPType.array) {
 *         foreach (obj; unpacked) {
 *             switch (obj.type) {
 *             case MPType.unsigned: writeln(obj.as!(uint)); break;
 *             case MPType.floating:            writeln(obj.as!(real)); break;
 *             defalut:
 *                 throw new Exception("Unknown type");
 *             }
 *         }
 *     } else {
 *         if (unpacked.type == MPType.boolean)
 *             writeln(unpacked.as!(bool));
 *         else
 *             writeln("Message: ", unpacked.as!(string));
 *     }
 * }
 * -----
 */
struct MPObject
{
    /**
     * msgpack value representation
     */
    static union Value
    {
        bool               boolean;   /// corresponding to MPType.boolean
        ulong              uinteger;  /// corresponding to MPType.unsigned
        long               integer;   /// corresponding to MPType.signed
        real               floating;  /// corresponding to MPType.floating
        MPObject[]         array;     /// corresponding to MPType.array
        MPObject[MPObject] map;       /// corresponding to MPType.map
        ubyte[]            raw;       /// corresponding to MPType.raw
    }


    MPType type;  /// represents object type 
    Value  via;   /// represents real value


    /**
     * Constructs a $(D MPObject) with arguments.
     *
     * Params:
     *  value = the real content.
     *  type  = the type of object.
     */
    @safe
    this(MPType type = MPType.nil)
    {
        this.type = type;
    }


    /// ditto
    @safe
    this(bool value, MPType type = MPType.boolean)
    {
        this(type);
        via.boolean = value;
    }


    /// ditto
    @safe
    this(ulong value, MPType type = MPType.unsigned)
    {
        this(type);
        via.uinteger = value;
    }


    /// ditto
    @safe
    this(long value, MPType type = MPType.signed)
    {
        this(type);
        via.integer = value;
    }


    /// ditto
    @safe
    this(real value, MPType type = MPType.floating)
    {
        this(type);
        via.floating = value;
    }


    /// ditto
    @safe
    this(MPObject[] value, MPType type = MPType.array)
    {
        this(type);
        via.array = value;
    }


    /// ditto
    @safe
    this(MPObject[MPObject] value, MPType type = MPType.map)
    {
        this(type);
        via.map = value;
    }


    /// ditto
    @safe
    this(ubyte[] value, MPType type = MPType.raw)
    {
        this(type);
        via.raw = value;
    }


    /**
     * Converts object value to $(D_PARAM T) type.
     *
     * Returns:
     *  converted value.
     *
     * Throws:
     *  InvalidTypeException if type is mismatched.
     *
     * NOTE:
     *  Current implementation uses cast.
     */
    @property @safe
    T as(T)() if (is(T == bool))
    {
        if (type != MPType.boolean)
            onCastError();

        return via.boolean;
    }


    /// ditto
    @property @safe
    T as(T)() if (isIntegral!T)
    {
        if (type == MPType.unsigned)
            return cast(T)via.uinteger;

        if (type == MPType.signed)
            return cast(T)via.integer;

        onCastError();

        assert(false);
    }


    /// ditto
    @property @safe
    T as(T)() if (isFloatingPoint!T)
    {
        if (type != MPType.floating)
            onCastError();

        return cast(T)via.floating;
    }


    /// ditto
    @property @safe
    T as(T)() if (is(Unqual!T == enum))
    {
        return cast(T)as!(OriginalType!T);
    }


    /// ditto
    @property @safe
    T as(T)() if (isArray!T)
    {
        alias typeof(T.init[0]) V;

        if (type == MPType.nil)
            return null;

        static if (isByte!V || isSomeChar!V) {
            if (type != MPType.raw)
                onCastError();

            return cast(T)via.raw;
        } else {
            if (type != MPType.array)
                onCastError();

            V[] array;

            foreach (elem; via.array)
                array ~= elem.as!(V);

            return array;
        }
    }


    /// ditto
    @property @trusted
    T as(T)() if (isAssociativeArray!T)
    {
        alias typeof(T.init.keys[0])   K;
        alias typeof(T.init.values[0]) V;

        if (type == MPType.nil)
            return null;

        if (type != MPType.map)
            onCastError();

        V[K] map;

        foreach (key, value; via.map)
            map[key.as!(K)] = value.as!(V);

        return map;
    }


    /**
     * Converts to $(D_PARAM T) type.
     *
     * $(D_KEYWORD struct) and $(D_KEYWORD class) need to implement $(D fromMsgpack) method.
     * $(D fromMsgpack) signature is:
     * -----
     * void fromMsgpack(MPObject object)
     * -----
     * Assumes $(D std.typecons.Tuple) if $(D_KEYWORD struct) doens't implement $(D fromMsgpack).
     *
     * Params:
     *  args = arguments to class constructor(class only).
     *
     * Returns:
     *  converted value.
     */
    @property /* @safe */
    T as(T, Args...)(Args args) if (is(T == class))
    {
        static if (!__traits(compiles, { T t; t.fromMsgpack(this); }))
            static assert(false, T.stringof ~ " is not a MessagePackable object");

        if (type == MPType.nil)
            return null;

        T object = new T(args);

        object.fromMsgpack(this);

        return object;
    }


    /// ditto
    @property /* @safe */
    T as(T)() if (is(T == struct))
    {
        T obj;

        static if (__traits(compiles, { T t; t.fromMsgpack(this); })) {
            obj.fromMsgpack(this);
        } else {
            foreach (i, Type; T.Types)
                obj.field[i] = via.array[i].as!(Type);
        }

        return obj;
    }


    /**
     * Special method called by $(D Packer).
     *
     * Params:
     *  packer = a MessagePack serializer.
     */
    void toMsgpack(Packer)(ref Packer packer) const
    {
        final switch (type) {
        case MPType.nil:
            packer.packNil();
            break;
        case MPType.boolean:
            packer.pack(via.boolean);
            break;
        case MPType.unsigned:
            packer.pack(via.uinteger);
            break;
        case MPType.signed:
            packer.pack(via.integer);
            break;
        case MPType.floating:
            packer.pack(via.floating);
            break;
        case MPType.raw:
            packer.pack(via.raw);
            break;
        case MPType.array:
            packer.beginArray(via.array.length);
            foreach (elem; via.array)
                elem.toMsgpack(packer);
            break;
        case MPType.map:
            packer.beginMap(via.map.length);
            foreach (key, value; via.map) {
                key.toMsgpack(packer);
                value.toMsgpack(packer);
            }
            break;
        }
    }


    /**
     * Comparison for equality.
     */
    @safe
    bool opEquals(Tdummy = void)(ref const MPObject other) const
    {
        if (type != other.type)
            return false;

        final switch (other.type) {
        case MPType.nil:              return true;
        case MPType.boolean:          return opEquals(other.via.boolean);
        case MPType.unsigned: return opEquals(other.via.uinteger);
        case MPType.signed: return opEquals(other.via.integer);
        case MPType.floating:            return opEquals(other.via.floating);
        case MPType.raw:              return opEquals(other.via.raw);
        case MPType.array:            return opEquals(other.via.array);
        case MPType.map:              return opEquals(other.via.map);
        }
    }


    /// ditto
    @safe
    bool opEquals(T : bool)(in T other) const
    {
        if (type != MPType.boolean)
            return false;

        return via.boolean == other;
    }


    /// ditto
    @safe
    bool opEquals(T : ulong)(in T other) const
    {
        static if (__traits(isUnsigned, T)) {
            if (type != MPType.unsigned)
                return false;

            return via.uinteger == other;
        } else {
            if (type != MPType.signed)
                return false;

            return via.integer == other;
        }
    }


    /// ditto
    @safe
    bool opEquals(T : real)(in T other) const
    {
        if (type != MPType.floating)
            return false;

        return via.floating == other;
    }


    /// ditto
    @safe
    bool opEquals(T : MPObject[])(in T other) const
    {
        if (type != MPType.array)
            return false;

        return via.array == other;
    }


    /// ditto
    @trusted
    bool opEquals(T : MPObject[MPObject])(in T other) const
    {
        if (type != MPType.map)
            return false;

        // This comparison is instead of default comparison because 'via.map == other' raises "Access Violation".
        foreach (key, value; via.map) {
            if (key in other) {
                if (other[key] != value)
                    return false;
            } else {
                return false;
            }
        }

        return true;
    }


    /// ditto
    @safe
    bool opEquals(T : ubyte[])(in T other) const
    {
        if (type != MPType.raw)
            return false;

        return via.raw == other;
    }
}


unittest
{
    // nil
    MPObject object = MPObject();
    MPObject other  = MPObject();

    assert(object      == other);
    assert(object.type == MPType.nil);

    // boolean
    object = MPObject(true);
    other  = MPObject(false);

    assert(object           != other);
    assert(object.type      == MPType.boolean);
    assert(object.as!(bool) == true);
    assert(other            == false);

    try {
        auto b = object.as!(uint);
        assert(false);
    } catch (InvalidTypeException e) { }

    // unsigned integer
    object = MPObject(10UL);
    other  = MPObject(10UL);

    assert(object           == other);
    assert(object.type      == MPType.unsigned);
    assert(object.as!(uint) == 10);
    assert(other            == 10UL);

    // signed integer
    object = MPObject(-20L);
    other  = MPObject(-10L);

    assert(object          != other);
    assert(object.type     == MPType.signed);
    assert(object.as!(int) == -20);
    assert(other           == -10L);

    // enum
    enum E : int { F = -20 }

    E e = object.as!(E);

    assert(e == E.F);

    // floating point
    object = MPObject(0.1e-10L);
    other  = MPObject(0.1e-20L);

    assert(object           != other);
    assert(object.type      == MPType.floating);
    assert(object.as!(real) == 0.1e-10L);
    assert(other            == 0.1e-20L);

    // raw
    object = MPObject(cast(ubyte[])[72, 105, 33]);
    other  = MPObject(cast(ubyte[])[72, 105, 33]);

    assert(object             == other);
    assert(object.type        == MPType.raw);
    assert(object.as!(string) == "Hi!");
    assert(other              == cast(ubyte[])[72, 105, 33]);

    // array
    auto t = MPObject(cast(ubyte[])[72, 105, 33]);
    object = MPObject([t]);
    other  = MPObject([t]);

    assert(object               == other);
    assert(object.type          == MPType.array);
    assert(object.as!(string[]) == ["Hi!"]);
    assert(other                == [t]);

    // map
    object = MPObject([MPObject(1L):MPObject(2L)]);
    other  = MPObject([MPObject(1L):MPObject(1L)]);

    assert(object               != other);
    assert(object.type          == MPType.map);
    assert(object.as!(int[int]) == [1:2]);
    assert(other                == [MPObject(1L):MPObject(1L)]);

    object = MPObject(10UL);

    // struct
    static struct S
    {
        ulong num;

        void fromMsgpack(MPObject object) { num = object.via.uinteger; }
    }

    S s = object.as!(S);
    assert(s.num == 10);

    // class
    static class C
    {
        ulong num;

        void fromMsgpack(MPObject object) { num = object.via.uinteger; }
    }

    C c = object.as!(C);
    assert(c.num == 10);

    // std.typecons.Tuple
    object = MPObject([MPObject(true), MPObject(1UL), MPObject(cast(ubyte[])"Hi!")]);

    auto tuple = object.as!(Tuple!(bool, uint, string));
    assert(tuple.field[0] == true);
    assert(tuple.field[1] == 1u);
    assert(tuple.field[2] == "Hi!");

    /* 
     * non-MessagePackable object is stopped by static assert
     * static struct NonMessagePackable {}
     * auto nonMessagePackable = object.as!(NonMessagePackable);
     */
}


/**
 * $(D Unpacked) is a $(D Range) wrapper for stream deserialization result
 */
struct Unpacked
{
    MPObject object;  /// deserialized object

    alias object this;


    /**
     * Constructs a $(D Unpacked) with argument.
     *
     * Params:
     *  object = a deserialized object.
     */
    @safe
    this(ref MPObject object)
    {
        this.object = object;
    }


    /**
     * InputRange primitive operation that checks iteration state.
     *
     * Returns:
     *  true if there are no more elements to be iterated.
     */
    @property @safe
    nothrow bool empty() const  // std.array.empty isn't nothrow function
    {
        return (object.type == MPType.array) && !object.via.array.length;
    }


    /**
     * Range primitive operation that returns the length of the range.
     *
     * Returns:
     *  the number of objects.
     */
    @property
    size_t length()
    {
        return object.via.array.length;
    }


    /**
     * InputRange primitive operation that returns the currently iterated element.
     *
     * Returns:
     *  the deserialized $(D MPObject).
     */
    @property /* @safe */
    ref MPObject front()
    {
        return object.via.array.front;
    }


    /**
     * InputRange primitive operation that advances the range to its next element.
     */
    /* @safe */
    void popFront()
    {
        object.via.array.popFront();
    }


    /+
    /**
     * BidirectionalRange primitive operation that returns the rightmost element.
     *
     * Returns:
     *  the deserialized $(D MPObject).
     */
    @property /* @safe */
    ref MPObject back()
    {
        return object.via.array.back();
    }


    /**
     * BidirectionalRange primitive operation that pops the rightmost element.
     */
    /* @safe */
    void popBack()
    {
        object.via.array.popBack();
    }


    /**
     * RandomAccessRange primitive operation.
     *
     * Returns:
     *  the deserialized $(D MPObject) at $(D_PARAM n) position.
     */
    @safe
    nothrow ref MPObject opIndex(size_t n)
    {
        return object.via.array[n];
    }


    /**
     * Returns a slice of the range.
     *
     * Paramas:
     *  from = the start point of slicing.
     *  to   = the end point of slicing.
     *
     * Returns:
     *  the slice of MPObjects.
     */
    /* @safe */
    MPObject[] opSlice(size_t from, size_t to)
    {
        return object.via.array[from..to];
    }
    +/


    /**
     * Range primitive operation that returns the snapshot.
     *
     * Returns:
     *  the snapshot of this MPObject.
     */
    @property @safe
    Unpacked save()
    {
        return Unpacked(object);
    }
}


unittest
{
    static assert(isForwardRange!Unpacked);
    static assert(hasLength!Unpacked);
}


/**
 * This $(D Unpacker) is a $(D MessagePack) stream deserializer
 *
 * This implementation enables you to load multiple objects from a stream(like network).
 *
 * Example:
 * -----
 * ...
 * auto unpacker = unpacker(serializedData);
 * ...
 *
 * // appends new data to buffer if pre execute() call didn't finish deserialization.
 * unpacker.feed(newSerializedData);
 *
 * while (unpacker.execute()) {
 *     foreach (obj; unpacker.purge()) {
 *         // do stuff (obj is a MPObject)
 *     }
 * }
 * 
 * if (unpacker.size)
 *     throw new Exception("Message is too large");
 * -----
 */
struct Unpacker(UnpackerType Type : UnpackerType.stream)
{
  private:
    /*
     * Context state of deserialization
     */
    enum State
    {
        HEADER = 0x00,

        // Floating point, Unsigned, Signed interger (== header & 0x03)
        FLOAT = 0x0a,
        DOUBLE,
        UINT8,
        UINT16,
        UINT32,
        UINT64,
        INT8,
        INT16,
        INT32,
        INT64,

        // Container (== header & 0x01)
        RAW16 = 0x1a,
        RAW32,
        ARRAY16,
        ARRAY36,
        MAP16,
        MAP32,
        RAW,

        // D-specific type
        REAL
    }


    /*
     * Element type of container
     */
    enum ContainerElement
    {
        ARRAY_ITEM,
        MAP_KEY,
        MAP_VALUE
    }


    /*
     * Internal stack context
     */
    static struct Context
    {
        static struct Container
        {
            ContainerElement type;    // object container type
            MPObject         object;  // current object
            MPObject         key;     // for map object
            size_t           count;   // container length
        }

        State       state;  // current state of deserialization
        size_t      trail;  // current deserializing size
        size_t      top;    // current index of stack
        Container[] stack;  // storing objects
    }

    Context context_;  // stack environment for streaming deserialization

    mixin InternalBuffer;


  public:
    /**
     * Constructs a $(D Unpacker).
     *
     * Params:
     *  target     = byte buffer to deserialize
     *  bufferSize = size limit of buffer size
     */
    @safe
    this(in ubyte[] target, in size_t bufferSize = 8192)
    {
        initializeBuffer(target, bufferSize);
        initializeContext();
    }


    /**
     * Forwards to deserialized object.
     *
     * Returns:
     *  the $(D Unpacked) object contains deserialized object.
     */
    @property @safe
    Unpacked unpacked()
    {
        return Unpacked(context_.stack[0].object);
    }


    /**
     * Clears some states for next deserialization.
     */
    @safe
    nothrow void clear()
    {
        initializeContext();

        parsed_ = 0;
    }


    /**
     * Convenient method for unpacking and clearing states.
     *
     * Example:
     * -----
     * foreach (obj; unpacker.purge()) {
     *     // do stuff
     * }
     * -----
     * is equivalent to
     * -----
     * foreach (obj; unpacker.unpacked) {
     *     // do stuff
     * }
     * unpacker.clear();
     * -----
     *
     * Returns:
     *  the $(D Unpacked) object contains deserialized object.
     */
    @safe
    Unpacked purge()
    {
        auto result = Unpacked(context_.stack[0].object);

        clear();

        return result;
    }


    /**
     * Executes deserialization.
     *
     * Returns:
     *  true if deserialization has been completed, otherwise false.
     *
     * Throws:
     *  $(D UnpackException) when parse error occurs.
     */
    bool execute()
    {
        /*
         * Current implementation is very dirty(goto! goto!! goto!!!).
         * This Complexity for performance(avoid function call).
         */

        bool     ret;
        size_t   cur = offset_;
        MPObject obj;

        // restores before state
        auto state =  context_.state;
        auto trail =  context_.trail;
        auto top   =  context_.top;
        auto stack = &context_.stack;

        /*
         * Helper for container deserialization
         */
        bool startContainer(string Type)(ContainerElement type, size_t length)
        {
            mixin("callback" ~ Type ~ "((*stack)[top].object, length);");

            if (length == 0)
                return false;

            (*stack)[top].type  = type;
            (*stack)[top].count = length;
            (*stack).length     = ++top + 1;

            return true;
        }

        // non-deserialized data is nothing
        if (used_ - offset_ == 0)
            goto Labort;

        do {
          Lstart:
            if (state == State.HEADER) {
                const header = buffer_[cur];

                if (0x00 <= header && header <= 0x7f) {         // positive
                    callbackUInt(obj, header);
                    goto Lpush;
                } else if (0xe0 <= header && header <= 0xff) {  // negative
                    callbackInt(obj, cast(byte)header);
                    goto Lpush;
                } else if (0xa0 <= header && header <= 0xbf) {  // fix raw
                    trail = header & 0x1f;
                    if (trail == 0)
                        goto Lraw;
                    state = State.RAW;
                    cur++;
                    goto Lstart;
                } else if (0x90 <= header && header <= 0x9f) {  // fix array
                    if (!startContainer!"Array"(ContainerElement.ARRAY_ITEM, header & 0x0f))
                        goto Lpush;
                    goto Lagain;
                } else if (0x80 <= header && header <= 0x8f) {  // fix map
                    if (!startContainer!"Map"(ContainerElement.MAP_KEY, header & 0x0f))
                        goto Lpush;
                    goto Lagain;
                } else {
                    switch (header) {
                    case Format.UINT8:
                    case Format.UINT16:
                    case Format.UINT32:
                    case Format.UINT64:
                    case Format.INT8:
                    case Format.INT16:
                    case Format.INT32:
                    case Format.INT64:
                    case Format.FLOAT:
                    case Format.DOUBLE:
                        trail = 1 << (header & 0x03); // computes object size
                        state = cast(State)(header & 0x1f);
                        break;
                    case Format.REAL:
                        trail = RealSize;
                        state = State.REAL;
                        break;
                    case Format.ARRAY16:
                    case Format.ARRAY32:
                    case Format.MAP16:
                    case Format.MAP32:
                    case Format.RAW16:
                    case Format.RAW32:
                        trail = 2 << (header & 0x01);  // computes container size
                        state = cast(State)(header & 0x1f);
                        break;
                    case Format.NIL:
                        callbackNil(obj);
                        goto Lpush;
                    case Format.TRUE:
                        callbackBool(obj, true);
                        goto Lpush;
                    case Format.FALSE:
                        callbackBool(obj, false);
                        goto Lpush;
                    default:
                        throw new UnpackException("Unknown type");
                    }

                    cur++;
                    goto Lstart;
                }
            } else {
                // data lack for deserialization
                if (used_ - cur < trail)
                    goto Labort;

                const base = cur; cur += trail - 1;  // fix current position

                final switch (state) {
                case State.FLOAT:
                    _f temp;

                    temp.i = load32To!uint(buffer_[base..base + trail]);                    
                    callbackFloat(obj, temp.f);
                    goto Lpush;
                case State.DOUBLE:
                    _d temp;

                    temp.i = load64To!ulong(buffer_[base..base + trail]);
                    callbackFloat(obj, temp.f);
                    goto Lpush;
                case State.REAL:
                    const expb = base + ulong.sizeof;

                    version (NonX86)
                    {
                        CustomFloat!80 temp;

                        const frac = load64To!ulong (buffer_[base..expb]);
                        const exp  = load16To!ushort(buffer_[expb..expb + ushort.sizeof]);

                        temp.significand = frac;
                        temp.exponent    = exp & 0x7fff;
                        temp.sign        = exp & 0x8000 ? true : false;

                        // NOTE: temp.get!real is inf on non-x86 when deserialized value is larger than double.max.
                        callbackFloat(obj, temp.get!real);
                    }
                    else
                    {
                        _r temp;

                        temp.fraction = load64To!(typeof(temp.fraction))(buffer_[base..expb]);
                        temp.exponent = load16To!(typeof(temp.exponent))(buffer_[expb..expb + temp.exponent.sizeof]);

                        callbackFloat(obj, temp.f);
                    }

                    goto Lpush;
                case State.UINT8:
                    callbackUInt(obj, buffer_[base]);
                    goto Lpush;
                case State.UINT16:
                    callbackUInt(obj, load16To!ulong(buffer_[base..base + trail]));
                    goto Lpush;
                case State.UINT32:
                    callbackUInt(obj, load32To!ulong(buffer_[base..base + trail]));
                    goto Lpush;
                case State.UINT64:
                    callbackUInt(obj, load64To!ulong(buffer_[base..base + trail]));
                    goto Lpush;
                case State.INT8:
                    callbackInt(obj, cast(byte)buffer_[base]);
                    goto Lpush;
                case State.INT16:
                    callbackInt(obj, load16To!long(buffer_[base..base + trail]));
                    goto Lpush;
                case State.INT32:
                    callbackInt(obj, load32To!long(buffer_[base..base + trail]));
                    goto Lpush;
                case State.INT64:
                    callbackInt(obj, load64To!long(buffer_[base..base + trail]));
                    goto Lpush;
                case State.RAW: Lraw:
                    hasRaw_ = true;
                    callbackRaw(obj, buffer_[base..base + trail]);
                    goto Lpush;
                case State.RAW16:
                    trail = load16To!size_t(buffer_[base..base + trail]);
                    if (trail == 0)
                        goto Lraw;
                    state = State.RAW;
                    cur++;
                    goto Lstart;
                case State.RAW32:
                    trail = load32To!size_t(buffer_[base..base + trail]);
                    if (trail == 0)
                        goto Lraw;
                    state = State.RAW;
                    cur++;
                    goto Lstart;
                case State.ARRAY16:
                    if (!startContainer!"Array"(ContainerElement.ARRAY_ITEM,
                                                load16To!size_t(buffer_[base..base + trail])))
                        goto Lpush;
                    goto Lagain;
                case State.ARRAY36:
                    if (!startContainer!"Array"(ContainerElement.ARRAY_ITEM,
                                                load32To!size_t(buffer_[base..base + trail])))
                        goto Lpush;
                    goto Lagain;
                case State.MAP16:
                    if (!startContainer!"Map"(ContainerElement.MAP_KEY,
                                              load16To!size_t(buffer_[base..base + trail])))
                        goto Lpush;
                    goto Lagain;
                case State.MAP32:
                    if (!startContainer!"Map"(ContainerElement.MAP_KEY,
                                              load32To!size_t(buffer_[base..base + trail])))
                        goto Lpush;
                    goto Lagain;
                case State.HEADER:
                    break;
                }
            }

          Lpush:
            if (top == 0)
                goto Lfinish;

            auto container = &(*stack)[top - 1];

            final switch (container.type) {
            case ContainerElement.ARRAY_ITEM:
                container.object.via.array ~= obj;
                if (--container.count == 0) {
                    obj = container.object;
                    top--;
                    goto Lpush;
                }
                break;
            case ContainerElement.MAP_KEY:
                container.key  = obj;
                container.type = ContainerElement.MAP_VALUE;
                break;
            case ContainerElement.MAP_VALUE:
                container.object.via.map[container.key] = obj;
                if (--container.count == 0) {
                    obj = container.object;
                    top--;
                    goto Lpush;
                }
                container.type = ContainerElement.MAP_KEY;
            }

          Lagain:
            state = State.HEADER;
            cur++;
        } while (cur < used_);

        goto Labort;

      Lfinish:
        (*stack)[0].object = obj;
        ret = true;
        cur++;
        goto Lend;

      Labort:
        ret = false;

      Lend:
        context_.state = state;
        context_.trail = trail;
        context_.top   = top;
        parsed_       += cur - offset_;
        offset_        = cur;

        return ret;
    }


    /**
     * supports foreach. One loop provides $(D Unpacked) object contains execute() result.
     * This is convenient in case that $(D MessagePack) objects are continuous.
     */
    int opApply(scope int delegate(ref Unpacked) dg)
    {
        int result;

        while (execute()) {
            result = dg(Unpacked(context_.stack[0].object));
            if (result)
                break;

            clear();
        }

        return result;
    }


  private:
    /*
     * initializes internal stack environment.
     */
    @safe
    nothrow void initializeContext()
    {
        context_.state        = State.HEADER;
        context_.trail        = 0;
        context_.top          = 0;
        context_.stack.length = 1;
    }
}


/**
 * Helper for $(D Unpacker) construction.
 *
 * Params:
 *  target     = byte buffer to deserialize.
 *  bufferSize = size limit of buffer size.
 *
 * Returns:
 *  a $(D Unpacker) object instantiated and initialized according to the arguments.
 */
@safe
Unpacker!(Type) unpacker(UnpackerType Type = UnpackerType.stream)(in ubyte[] target, in size_t bufferSize = 8192)
{
    return typeof(return)(target, bufferSize);
}


unittest
{
    // serialize
    mixin DefinePacker;

    packer.packArray(null, true, 1, -2, "Hi!", [1], [1:1], double.max);

    // deserialize
    auto unpacker = unpacker(packer.stream.data); unpacker.execute();
    auto unpacked = unpacker.purge();

    // Range test
    foreach (unused; 0..2) {
        uint i;

        foreach (obj; unpacked)
            i++;

        assert(i == unpacked.via.array.length);
    }

    auto result = unpacked.via.array;

    assert(result[0].type          == MPType.nil);
    assert(result[1].via.boolean   == true);
    assert(result[2].via.uinteger  == 1);
    assert(result[3].via.integer   == -2);
    assert(result[4].via.raw       == [72, 105, 33]);
    assert(result[5].as!(int[])    == [1]);
    assert(result[6].as!(int[int]) == [1:1]);
    assert(result[7].as!(double)   == double.max);
}


private:


/*
 * Sets object type and value.
 *
 * Params:
 *  object = the object to set
 *  value  = the content to set
 */
@safe
void callbackUInt(ref MPObject object, ulong value)
{
    object.type         = MPType.unsigned;
    object.via.uinteger = value;
}


/// ditto
@safe
void callbackInt(ref MPObject object, long value)
{
    object.type        = MPType.signed;
    object.via.integer = value;
}


/// ditto
@safe
void callbackFloat(ref MPObject object, real value)
{
    object.type         = MPType.floating;
    object.via.floating = value;
}


/// ditto
@safe
void callbackRaw(ref MPObject object, ubyte[] raw)
{
    object.type    = MPType.raw;
    object.via.raw = raw;
}


/// ditto
@trusted
void callbackArray(ref MPObject object, size_t length)
{
    object.type = MPType.array;
    object.via.array.length = 0;
    object.via.array.reserve(length);
}


/// ditto
@safe
void callbackMap(ref MPObject object, lazy size_t length)
{
    object.type    = MPType.map;
    object.via.map = null;  // clears previous result avoiding 'Access Violation'
}


/// ditto
@safe
void callbackNil(ref MPObject object)
{
    object.type = MPType.nil;
}


/// ditto
@safe
void callbackBool(ref MPObject object, bool value)
{
    object.type        = MPType.boolean;
    object.via.boolean = value;
}


unittest
{
    MPObject object;

    // Unsigned integer
    callbackUInt(object, uint.max);
    assert(object.type         == MPType.unsigned);
    assert(object.via.uinteger == uint.max);

    // Signed integer
    callbackInt(object, int.min);
    assert(object.type        == MPType.signed);
    assert(object.via.integer == int.min);

    // Floating point
    callbackFloat(object, real.max);
    assert(object.type         == MPType.floating);
    assert(object.via.floating == real.max);

    // Raw
    callbackRaw(object, cast(ubyte[])[1]);
    assert(object.type    == MPType.raw);
    assert(object.via.raw == cast(ubyte[])[1]);

    // Array
    MPObject[] array; array.reserve(16);

    callbackArray(object, 16);
    assert(object.type               == MPType.array);
    assert(object.via.array.capacity == array.capacity);

    // Map
    MPObject[MPObject] map;

    callbackMap(object, 16);
    assert(object.type    == MPType.map);
    assert(object.via.map == null);

    // NIL
    callbackNil(object);
    assert(object.type == MPType.nil);

    // Bool
    callbackBool(object, true);
    assert(object.type        == MPType.boolean);
    assert(object.via.boolean == true);
}


private:


/*
 * A callback for type-mismatched error in cast conversion.
 */
@safe
pure void onCastError()
{
    throw new InvalidTypeException("Attempt to cast with another type");
}


/*
 * A callback for type-mismatched error in deserialization process.
 */
@safe
pure void onInvalidType()
{
    throw new InvalidTypeException("Attempt to unpack with non-compatible type");
}


public:


// Convenient functions


/**
 * Serializes $(D_PARAM args).
 *
 * Assumes single object if the length of $(D_PARAM args) == 1,
 * otherwise array object.
 *
 * Params:
 *  args = the contents to serialize.
 *
 * Returns:
 *  a serialized data.
 */
ubyte[] pack(Args...)(in Args args)
{
    auto packer = packer(Appender!(ubyte[])());

    static if (Args.length == 1)
        packer.pack(args[0]);
    else
        packer.packArray(args);

    return packer.stream.data;
}


unittest
{
    auto serialized = pack(false);

    assert(serialized[0] == Format.FALSE);

    auto deserialized = unpack(pack(1, true, "Foo"));

    assert(deserialized.type == MPType.array);
    assert(deserialized.via.array[0].type == MPType.unsigned);
    assert(deserialized.via.array[1].type == MPType.boolean);
    assert(deserialized.via.array[2].type == MPType.raw);
}


/**
 * Deserializes $(D_PARAM buffer) using stream deserializer.
 *
 * Params:
 *  buffer = the buffer to deserialize.
 *
 * Returns:
 *  a $(D Unpacked) contains deserialized object.
 *
 * Throws:
 *  UnpackException if deserialization doesn't succeed.
 */
Unpacked unpack(Tdummy = void)(in ubyte[] buffer)
{
    auto unpacker = unpacker(buffer);

    if (!unpacker.execute())
        throw new UnpackException("Deserialization failure");

    return unpacker.unpacked;
}


/**
 * Deserializes $(D_PARAM buffer) using direct conversion deserializer.
 *
 * Assumes single object if the length of $(D_PARAM args) == 1,
 * otherwise array object.
 *
 * Params:
 *  buffer = the buffer to deserialize.
 *  args   = the references of values to assign.
 */
void unpack(Args...)(in ubyte[] buffer, ref Args args)
{
    auto unpacker = unpacker!(UnpackerType.direct)(buffer);

    static if (Args.length == 1)
        unpacker.unpack(args[0]);
    else
        unpacker.unpackArray(args);
}


unittest
{
    { // stream
        auto result = unpack(pack(false));

        assert(result.via.boolean == false);
    }
    { // direct conversion
        Tuple!(uint, string) result, test = tuple(1, "Hi!");
        
        unpack(pack(test), result);

        assert(result == test);

        test.field[0] = 2;
        test.field[1] = "Hey!";

        unpack(pack(test.field[0], test.field[1]), result.field[0], result.field[1]);

        assert(result == test);
    }
}


// Utilities template


/**
 * Handy helper for creating MessagePackable object.
 *
 * toMsgpack / fromMsgpack are special methods for serialization / deserialization.
 * This template provides those methods to struct/class.
 *
 * Example:
 * -----
 * struct S
 * {
 *     int num; string str;
 *
 *     // http://d.puremagic.com/issues/show_bug.cgi?id = 1099
 *     mixin MessagePackable;  // all members
 *     // mixin MessagePackable!("num");  // num only
 * }
 * -----
 *
 * Defines those methods manually if you treat complex data-structure.
 */
mixin template MessagePackable(Members...)
{
    static if (Members.length == 0) {
        /**
         * Serializes members using $(D_PARAM packer).
         *
         * Params:
         *  packer = the serializer to pack.
         */
        void toMsgpack(Packer)(ref Packer packer) const
        {
            packer.beginArray(this.tupleof.length);
            foreach (member; this.tupleof)
                packer.pack(member);
        }


        /**
         * Deserializes $(D MessagePack) object to members using MPObject.
         *
         * Params:
         *  object = the MessagePack object to unpack.
         *
         * Throws:
         *  InvalidTypeException if $(D_PARAM object) is not an Array type.
         */
        void fromMsgpack(MPObject object)
        {
            // enables if std.contracts.enforce is moved to object_.d
            // enforceEx!InvalidTypeException(object.type == MPType.array, "MPObject must be Array type");
            if (object.type != MPType.array)
                throw new InvalidTypeException("MPObject must be an Array type");
            if (object.via.array.length != this.tupleof.length)
                throw new InvalidTypeException("The size of deserialized object is mismatched");

            foreach (i, member; this.tupleof)
                this.tupleof[i] = object.via.array[i].as!(typeof(member));
        }


        /**
         * Deserializes $(D MessagePack) object to members using direct-conversion deserializer.
         *
         * Params:
         *  object = the reference to direct-conversion deserializer.
         *
         * Throws:
         *  InvalidTypeException if the size of deserialized object is mismatched.
         */
        void fromMsgpack(ref Unpacker!(UnpackerType.direct) unpacker)
        {
            auto length = unpacker.beginArray();
            if (length != this.tupleof.length)
                throw new InvalidTypeException("The size of deserialized object is mismatched");

            foreach (i, member; this.tupleof)
                unpacker.unpack(this.tupleof[i]);
        }
    } else {
        /**
         * Member selecting version of toMsgpack.
         */
        void toMsgpack(Packer)(ref Packer packer) const
        {
            packer.beginArray(Members.length);
            foreach (member; Members)
                packer.pack(mixin(member));
        }


        /**
         * Member selecting version of fromMsgpack for MPObject.
         */
        void fromMsgpack(MPObject object)
        {
            if (object.type != MPType.array)
                throw new InvalidTypeException("MPObject must be an Array type");
            if (object.via.array.length != Members.length)
                throw new InvalidTypeException("The size of deserialized object is mismatched");

            foreach (i, member; Members)
                mixin(member ~ "= object.via.array[i].as!(typeof(" ~ member ~ "));");
        }


        /**
         * Member selecting version of fromMsgpack for direct-converion deserializer.
         */
        void fromMsgpack(ref Unpacker!(UnpackerType.direct) unpacker)
        {
            auto length = unpacker.beginArray();
            if (length != Members.length)
                throw new InvalidTypeException("The size of deserialized object is mismatched");

            foreach (member; Members)
                unpacker.unpack(mixin(member));
        }
    }
}


unittest
{
    { // all members
        static struct S
        {
            uint num; string str;
            mixin MessagePackable;
        }

        mixin DefinePacker;

        S orig = S(10, "Hi!"); orig.toMsgpack(packer);

        { // stream
            auto unpacker = unpacker(packer.stream.data); unpacker.execute();

            S result; result.fromMsgpack(unpacker.unpacked);

            assert(result.num == 10);
            assert(result.str == "Hi!");
        }
        { // direct conversion
            auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);

            S result; unpacker.unpack(result);

            assert(result.num == 10);
            assert(result.str == "Hi!");
        }
    }
    { // member select
        static class C
        {
            uint num; string str;

            this() {}
            this(uint n, string s) { num = n; str = s; }

            mixin MessagePackable!("num");
        }

        mixin DefinePacker;

        C orig = new C(10, "Hi!"); orig.toMsgpack(packer);

        { // stream
            auto unpacker = unpacker(packer.stream.data); unpacker.execute();

            C result = new C; result.fromMsgpack(unpacker.unpacked);

            assert(result.num == 10);
        }
        { // direct conversion
            auto unpacker = unpacker!(UnpackerType.direct)(packer.stream.data);

            C result; unpacker.unpack(result);

            assert(result.num == 10);
        }
    }
}


private:


// Common and system dependent operations


/*
 * MessagePack type-information format
 *
 * See_Also:
 *  $(LINK2 http://redmine.msgpack.org/projects/msgpack/wiki/FormatSpec, MessagePack Specificaton)
 */
enum Format : ubyte
{
    // unsinged integer
    UINT8  = 0xcc,  // ubyte
    UINT16 = 0xcd,  // ushort
    UINT32 = 0xce,  // uint
    UINT64 = 0xcf,  // ulong

    // signed integer
    INT8  = 0xd0,   // byte
    INT16 = 0xd1,   // short
    INT32 = 0xd2,   // int
    INT64 = 0xd3,   // long

    // floating point
    FLOAT  = 0xca,  // float
    DOUBLE = 0xcb,  // double

    // raw byte
    RAW   = 0xa0,
    RAW16 = 0xda,
    RAW32 = 0xdb,

    // array
    ARRAY   = 0x90,
    ARRAY16 = 0xdc,
    ARRAY32 = 0xdd,

    // map
    MAP   = 0x80,
    MAP16 = 0xde,
    MAP32 = 0xdf,

    // other
    NIL   = 0xc0,   // null
    TRUE  = 0xc3,
    FALSE = 0xc2,

    // real (This format is D only!)
    REAL = 0xd4
}


/*
 * For float type serialization / deserialization
 */
union _f
{
    float f;
    uint  i;
}


/*
 * For double type serialization / deserialization
 */
union _d
{
    double f;
    ulong  i;
}


/*
 * For real type serialization / deserialization
 *
 * 80-bit real is padded to 12 bytes(Linux) and 16 bytes(Mac).
 * http://lists.puremagic.com/pipermail/digitalmars-d/2010-June/077394.html
 */
union _r
{
    real f;

    struct
    {
        ulong  fraction;
        ushort exponent;  // includes sign
    }
}

enum RealSize = 10;  // Real size is 80bit


/*
 * Detects whether $(D_PARAM T) is a built-in byte type.
 */
template isByte(T)
{
    enum isByte = staticIndexOf!(Unqual!T, byte, ubyte) >= 0;
}


unittest
{
    static assert(isByte!(byte));
    static assert(isByte!(const(byte)));
    static assert(isByte!(ubyte));
    static assert(isByte!(immutable(ubyte)));
    static assert(!isByte!(short));
    static assert(!isByte!(char));
    static assert(!isByte!(string));
}


/*
 * Gets asterisk string from pointer type
 */
template AsteriskOf(T)
{
    static if (is(T P == U*, U))
        enum AsteriskOf = "*" ~ AsteriskOf!U;
    else
        enum AsteriskOf = "";
}


version (LittleEndian)
{
    /*
     * Converts $(value) to different Endian.
     *
     * Params:
     *  value = the LittleEndian value to convert.
     *
     * Returns:
     *  the converted value.
     */
    @trusted
    ushort convertEndianTo(size_t Bit, T)(in T value) if (Bit == 16)
    {
        return ntohs(cast(ushort)value);
    }


    // ditto
    @trusted
    uint convertEndianTo(size_t Bit, T)(in T value) if (Bit == 32)
    {
        return ntohl(cast(uint)value);
    }


    // ditto
    @trusted
    ulong convertEndianTo(size_t Bit, T)(in T value) if (Bit == 64)
    {
        // dmd has convert function?
        return ((((cast(ulong)value) << 56) & 0xff00000000000000UL) |
                (((cast(ulong)value) << 40) & 0x00ff000000000000UL) |
                (((cast(ulong)value) << 24) & 0x0000ff0000000000UL) |
                (((cast(ulong)value) <<  8) & 0x000000ff00000000UL) |
                (((cast(ulong)value) >>  8) & 0x00000000ff000000UL) |
                (((cast(ulong)value) >> 24) & 0x0000000000ff0000UL) |
                (((cast(ulong)value) >> 40) & 0x000000000000ff00UL) |
                (((cast(ulong)value) >> 56) & 0x00000000000000ffUL));
    }


    unittest
    {
        assert(convertEndianTo!16(0x0123)             == 0x2301);
        assert(convertEndianTo!32(0x01234567)         == 0x67452301);
        assert(convertEndianTo!64(0x0123456789abcdef) == 0xefcdab8967452301);
    }


    /*
     * Comapatible for BigEndian environment.
     */
    ubyte take8from(size_t bit = 8, T)(T value)
    {
        static if (bit == 8 || bit == 16 || bit == 32 || bit == 64)
            return (cast(ubyte*)&value)[0];
        else
            static assert(false, bit.stringof ~ " is not support bit width.");
    }


    unittest
    {
        foreach (Integer; TypeTuple!(ubyte, ushort, uint, ulong)) {
            assert(take8from!8 (cast(Integer)0x01)               == 0x01);
            assert(take8from!16(cast(Integer)0x0123)             == 0x23);
            assert(take8from!32(cast(Integer)0x01234567)         == 0x67);
            assert(take8from!64(cast(Integer)0x0123456789abcdef) == 0xef);
        }
    }
}
else
{
    /*
     * Comapatible for LittleEndian environment.
     */
    @safe
    ushort convertEndianTo(size_t Bit, T)(in T value) if (Bit == 16)
    {
        return cast(ushort)value;
    }


    // ditto
    @safe
    uint convertEndianTo(size_t Bit, T)(in T value) if (Bit == 32)
    {
        return cast(uint)value;
    }


    // ditto
    @safe
    ulong convertEndianTo(size_t Bit, T)(in T value) if (Bit == 64)
    {
        return cast(ulong)value;
    }


    unittest
    {
        assert(convertEndianTo!16(0x0123)       == 0x0123);
        assert(convertEndianTo!32(0x01234567)   == 0x01234567);
        assert(convertEndianTo!64(0x0123456789) == 0x0123456789);
    }


    /*
     * Takes 8bit from $(D_PARAM value)
     *
     * Params:
     *  value = the content to take.
     *
     * Returns:
     *  the 8bit value corresponding $(D_PARAM bit) width.
     */
    ubyte take8from(size_t bit = 8, T)(T value)
    {
        static if (bit == 8)
            return (cast(ubyte*)&value)[0];
        else static if (bit == 16)
            return (cast(ubyte*)&value)[1];
        else static if (bit == 32)
            return (cast(ubyte*)&value)[3];
        else static if (bit == 64)
            return (cast(ubyte*)&value)[7];
        else
            static assert(false, bit.stringof ~ " is not support bit width.");
    }


    unittest
    {
        foreach (Integer; TypeTuple!(ubyte, ushort, uint, ulong)) {
            assert(take8from!8 (cast(Integer)0x01)               == 0x01);
            assert(take8from!16(cast(Integer)0x0123)             == 0x23);
            assert(take8from!32(cast(Integer)0x01234567)         == 0x67);
            assert(take8from!64(cast(Integer)0x0123456789abcdef) == 0xef);
        }
    }
}


/*
 * Loads $(D_PARAM T) type value from $(D_PARAM buffer).
 *
 * Params:
 *  buffer = the serialized contents.
 *
 * Returns:
 *  the Endian-converted value.
 */
T load16To(T)(ubyte[] buffer)
{
    return cast(T)(convertEndianTo!16(*cast(ushort*)buffer.ptr));
}


// ditto
T load32To(T)(ubyte[] buffer)
{
    return cast(T)(convertEndianTo!32(*cast(uint*)buffer.ptr));
}


// ditto
T load64To(T)(ubyte[] buffer)
{
    return cast(T)(convertEndianTo!64(*cast(ulong*)buffer.ptr));
}
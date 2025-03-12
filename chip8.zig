const c = @cImport({
    @cInclude("SDL2/SDL.h");
});
const std = @import("std");
const time = std.time;
const fs = std.fs;
const File = fs.File;
const allocator = std.heap.page_allocator;
var rand: std.Random = undefined;

const RAM_SIZE: usize = 4096;
const SCREEN_WIDTH: usize = 64;
const SCREEN_HEIGHT: usize = 32;
const SCREEN_SIZE: usize = SCREEN_WIDTH * SCREEN_HEIGHT;
const NUM_REGS: usize = 16;
const STACK_SIZE: usize = 16;
const NUM_KEYS: usize = 16;
const START_ADDR: u16 = 0x200;
const FONTSET_SIZE: usize = 80;
const FONTSET: [FONTSET_SIZE]u8 = .{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

const Chip8 = struct {
    pc: u16,
    ram: [RAM_SIZE]u8,
    screen: [SCREEN_SIZE]bool,
    v: [NUM_REGS]u8,
    i: u16,
    stack: [STACK_SIZE]u16,
    sp: u16, // points to the top of the stack
    keys: [NUM_KEYS]bool,
    dt: u8,
    st: u8,

    display_updated: bool = false,

    const Res = enum {
        Next,
        Skip,
        Jump,
        var jump_addr: u16 = START_ADDR;
    };

    pub fn new() Chip8 {
        var chip8 = Chip8{
            .pc = START_ADDR,
            .ram = [_]u8{0} ** RAM_SIZE,
            .screen = [_]bool{false} ** (SCREEN_SIZE),
            .v = [_]u8{0} ** NUM_REGS,
            .i = 0,
            .stack = [_]u16{0} ** STACK_SIZE,
            .sp = 0,
            .keys = [_]bool{false} ** NUM_KEYS,
            .dt = 0,
            .st = 0,
        };
        for (0..FONTSET_SIZE) |i| {
            chip8.ram[i] = FONTSET[i];
        }
        return chip8;
    }

    pub fn reset(self: *Chip8) void {
        self.pc = START_ADDR;
        self.ram = [_]u8{0} ** RAM_SIZE;
        self.screen = [_]bool{false} ** (SCREEN_SIZE);
        self.v = [_]u8{0} ** NUM_REGS;
        self.i = 0;
        self.stack = [_]u16{0} ** STACK_SIZE;
        self.sp = 0;
        self.keys = [_]bool{false} ** NUM_KEYS;
        self.dt = 0;
        self.st = 0;
        for (0..FONTSET_SIZE) |i| {
            self.ram[i] = FONTSET[i];
        }
    }

    pub fn load(self: *Chip8, rom: []u8) void {
        for (0..rom.len) |i| {
            self.ram[START_ADDR + i] = rom[i];
        }
    }

    fn push(self: *Chip8, val: u16) void {
        self.sp += 1;
        self.stack[self.sp] = val;
    }

    fn pop(self: *Chip8) u16 {
        const ret = self.stack[self.sp];
        self.sp -= 1;
        return ret;
    }

    fn fetch(self: *Chip8) u16 {
        const op: u16 = @as(u16, self.ram[self.pc]) << 8 | self.ram[self.pc + 1];
        return op;
    }

    // ===== instructions =====
    fn cls(self: *Chip8) Res {
        for (0..SCREEN_SIZE) |i| {
            self.screen[i] = false;
        }
        return Res.Next;
    }

    fn return_from_subroutine(self: *Chip8) Res {
        self.pc = self.pop();
        return Res.Next;
    }

    fn jump(self: *Chip8, nnn: u16) Res {
        _ = self;
        Res.jump_addr = nnn;
        return Res.Jump;
    }

    fn call_subroutine(self: *Chip8, nnn: u16) Res {
        self.push(self.pc);
        Res.jump_addr = nnn;
        return Res.Jump;
    }

    fn skip_if_vx_eq_kk(self: *Chip8, x: u8, kk: u8) Res {
        return if (self.v[x] == kk) Res.Skip else Res.Next;
    }

    fn skip_if_vx_neq_kk(self: *Chip8, x: u8, kk: u8) Res {
        return if (self.v[x] != kk) Res.Skip else Res.Next;
    }

    fn skip_if_vx_eq_vy(self: *Chip8, x: u8, y: u8) Res {
        return if (self.v[x] == self.v[y]) Res.Skip else Res.Next;
    }

    fn load_vx_kk(self: *Chip8, x: u8, kk: u8) Res {
        self.v[x] = kk;
        return Res.Next;
    }

    fn add_kk_to_vx(self: *Chip8, x: u8, kk: u8) Res {
        self.v[x] +%= kk;
        return Res.Next;
    }

    fn load_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[x] = self.v[y];
        return Res.Next;
    }

    fn or_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[x] |= self.v[y];
        return Res.Next;
    }

    fn and_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[x] &= self.v[y];
        return Res.Next;
    }

    fn xor_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[x] ^= self.v[y];
        return Res.Next;
    }

    fn add_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        const sum: u16 = @as(u16, self.v[x]) +% @as(u16, self.v[y]);
        self.v[0xF] = if (255 < sum) 1 else 0;
        self.v[x] = @intCast(sum & 0xFF);
        return Res.Next;
    }

    fn sub_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[0xF] = if (self.v[y] < self.v[x]) 1 else 0;
        self.v[x] -%= self.v[y];
        return Res.Next;
    }

    fn shr_vx(self: *Chip8, x: u8) Res {
        self.v[0xF] = self.v[x] & 0x1;
        self.v[x] >>= 1;
        return Res.Next;
    }

    fn subn_vx_vy(self: *Chip8, x: u8, y: u8) Res {
        self.v[0xF] = if (self.v[x] < self.v[y]) 1 else 0;
        self.v[x] = self.v[y] -% self.v[x];
        return Res.Next;
    }

    fn shl_vx(self: *Chip8, x: u8) Res {
        self.v[0xF] = self.v[x] >> 7;
        self.v[x] <<= 1;
        return Res.Next;
    }

    fn skip_if_vx_neq_vy(self: *Chip8, x: u8, y: u8) Res {
        return if (self.v[x] != self.v[y]) Res.Skip else Res.Next;
    }

    fn load_i(self: *Chip8, nnn: u16) Res {
        self.i = nnn;
        return Res.Next;
    }

    fn jump_v0(self: *Chip8, nnn: u16) Res {
        Res.jump_addr = nnn + @as(u16, self.v[0]);
        return Res.Jump;
    }

    fn rnd(self: *Chip8, x: u8, kk: u8) Res {
        self.v[x] = rand.int(u8) & kk;
        return Res.Next;
    }

    fn draw(self: *Chip8, x: u8, y: u8, n: u8) Res {
        const x_coord = @as(u16, self.v[x]);
        const y_coord = @as(u16, self.v[y]);
        var flipped = false;
        for (0..n) |y_line| {
            const addr: usize = self.i + y_line;
            const pixels = self.ram[addr];
            for (0..8) |x_line| {
                const shift_amt: u3 = @truncate(x_line);
                if (pixels & (@as(u8, 0b1000_0000) >> shift_amt) != 0) {
                    const xx = (x_coord + x_line) % SCREEN_WIDTH;
                    const yy = (y_coord + y_line) % SCREEN_HEIGHT;
                    const index = yy * SCREEN_WIDTH + xx;
                    flipped = flipped or self.screen[index];
                    self.screen[index] = !self.screen[index];
                }
            }
        }
        self.v[0xF] = if (flipped) 1 else 0;
        self.display_updated = true;
        return Res.Next;
    }

    fn skip_if_key_pressed(self: *Chip8, x: u8) Res {
        const vx = self.v[x];
        return if (self.keys[vx] == true) Res.Skip else Res.Next;
    }

    fn skip_if_key_not_pressed(self: *Chip8, x: u8) Res {
        const vx = self.v[x];
        return if (self.keys[vx] == false) Res.Skip else Res.Next;
    }

    fn load_vx_dt(self: *Chip8, x: u8) Res {
        self.v[x] = self.dt;
        return Res.Next;
    }

    fn load_vx_key(self: *Chip8, x: u8) Res {
        for (0..NUM_KEYS) |i| {
            if (self.keys[i] == true) {
                self.v[x] = @intCast(i);
                return Res.Next;
            }
        }
        self.pc -= 2;
        return Res.Next;
    }

    fn load_dt_vx(self: *Chip8, x: u8) Res {
        self.dt = self.v[x];
        return Res.Next;
    }

    fn load_st_vx(self: *Chip8, x: u8) Res {
        self.st = self.v[x];
        return Res.Next;
    }

    fn add_i_vx(self: *Chip8, x: u8) Res {
        self.i += @as(u16, self.v[x]);
        return Res.Next;
    }

    fn load_font_vx(self: *Chip8, x: u8) Res {
        self.i = @as(u16, self.v[x]) * 5;
        return Res.Next;
    }

    fn store_bcd_vx(self: *Chip8, x: u8) Res {
        self.ram[self.i] = self.v[x] / 100;
        self.ram[self.i + 1] = (self.v[x] / 10) % 10;
        self.ram[self.i + 2] = self.v[x] % 10;
        return Res.Next;
    }

    fn store_regs(self: *Chip8, x: u8) Res {
        for (0..x) |i| {
            self.ram[self.i + i] = self.v[i];
        }
        return Res.Next;
    }

    fn load_regs(self: *Chip8, x: u8) Res {
        for (0..x) |i| {
            self.v[i] = self.ram[self.i + i];
        }
        return Res.Next;
    }

    fn execute(self: *Chip8, op: u16) void {
        const nnn: u16 = op & 0x0FFF;
        const kk: u8 = @intCast(op & 0x00FF);
        const x: u8 = @intCast((op & 0x0F00) >> 8);
        const y: u8 = @intCast((op & 0x00F0) >> 4);
        const n: u8 = @intCast(op & 0x000F);

        const res = switch (op & 0xF000) {
            0x0000 => switch (op) {
                0x00E0 => self.cls(),
                0x00EE => self.return_from_subroutine(),
                else => unreachable,
            },
            0x1000 => self.jump(nnn),
            0x2000 => self.call_subroutine(nnn),
            0x3000 => self.skip_if_vx_eq_kk(x, kk),
            0x4000 => self.skip_if_vx_neq_kk(x, kk),
            0x5000 => self.skip_if_vx_eq_vy(x, y),
            0x6000 => self.load_vx_kk(x, kk),
            0x7000 => self.add_kk_to_vx(x, kk),
            0x8000 => switch (op & 0x000F) {
                0x0000 => self.load_vx_vy(x, y),
                0x0001 => self.or_vx_vy(x, y),
                0x0002 => self.and_vx_vy(x, y),
                0x0003 => self.xor_vx_vy(x, y),
                0x0004 => self.add_vx_vy(x, y),
                0x0005 => self.sub_vx_vy(x, y),
                0x0006 => self.shr_vx(x),
                0x0007 => self.subn_vx_vy(x, y),
                0x000E => self.shl_vx(x),
                else => unreachable,
            },
            0x9000 => self.skip_if_vx_neq_vy(x, y),
            0xA000 => self.load_i(nnn),
            0xB000 => self.jump_v0(nnn),
            0xC000 => self.rnd(x, kk),
            0xD000 => self.draw(x, y, n),
            0xE000 => switch (op & 0x00FF) {
                0x009E => self.skip_if_key_pressed(x),
                0x00A1 => self.skip_if_key_not_pressed(x),
                else => unreachable,
            },
            0xF000 => switch (op & 0x00FF) {
                0x0007 => self.load_vx_dt(x),
                0x000A => self.load_vx_key(x),
                0x0015 => self.load_dt_vx(x),
                0x0018 => self.load_st_vx(x),
                0x001E => self.add_i_vx(x),
                0x0029 => self.load_font_vx(x),
                0x0033 => self.store_bcd_vx(x),
                0x0055 => self.store_regs(x),
                0x0065 => self.load_regs(x),
                else => unreachable,
            },
            else => unreachable,
        };

        switch (res) {
            Res.Next => self.pc += 2,
            Res.Skip => self.pc += 4,
            Res.Jump => self.pc = Res.jump_addr,
        }
    }

    fn tick_timers(self: *Chip8) void {
        if (self.dt > 0) self.dt -= 1;
        if (self.st > 0) {
            if (self.st == 1) {
                // Beep
            }
            self.st -= 1;
        }
    }

    pub fn tick(self: *Chip8) void {
        const op = self.fetch();
        self.display_updated = false;
        self.execute(op);
    }

    pub fn display(self: *Chip8) void {
        for (0..SCREEN_HEIGHT) |y| {
            for (0..SCREEN_WIDTH) |x| {
                const index = y * SCREEN_WIDTH + x;
                if (self.screen[index] == true) {
                    std.debug.print("#", .{});
                } else {
                    std.debug.print(" ", .{});
                }
            }
            std.debug.print("\n", .{});
        }
    }
};

const KEYMAP = [_]c.SDL_Keycode{
    c.SDLK_x, // 0
    c.SDLK_1, // 1
    c.SDLK_2, // 2
    c.SDLK_3, // 3
    c.SDLK_q, // 4
    c.SDLK_w, // 5
    c.SDLK_e, // 6
    c.SDLK_a, // 7
    c.SDLK_s, // 8
    c.SDLK_d, // 9
    c.SDLK_z, // A
    c.SDLK_c, // B
    c.SDLK_4, // C
    c.SDLK_r, // D
    c.SDLK_f, // E
    c.SDLK_v, // F
};

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(@intCast(time.milliTimestamp()));
    rand = prng.random();

    const args = std.process.argsAlloc(allocator) catch |err| {
        std.debug.print("Error getting args: {any}\n", .{err});
        return;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: chip8 <rom>\n", .{});
        return;
    }

    var chip8 = Chip8.new();
    const rom = fs.cwd().readFileAlloc(allocator, args[1], RAM_SIZE - START_ADDR) catch |err| {
        std.debug.print("Error reading file: {any}\n", .{err});
        return;
    };
    defer allocator.free(rom);
    chip8.load(rom);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    const screen = c.SDL_CreateWindow("Chip8", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, 10 * SCREEN_WIDTH, 10 * SCREEN_HEIGHT, c.SDL_WINDOW_OPENGL) orelse
        {
            c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };
    defer c.SDL_DestroyWindow(screen);

    const renderer = c.SDL_CreateRenderer(screen, -1, 0) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);

    const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_RGBA8888, c.SDL_TEXTUREACCESS_TARGET, SCREEN_WIDTH, SCREEN_HEIGHT) orelse {
        c.SDL_Log("Unable to create texture: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyTexture(texture);
    const pixel_buffer = try allocator.alloc(u32, SCREEN_HEIGHT * SCREEN_WIDTH);
    defer allocator.free(pixel_buffer);

    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_KEYDOWN => {
                    for (0..NUM_KEYS) |i| {
                        if (event.key.keysym.sym == KEYMAP[i]) {
                            chip8.keys[i] = true;
                        }
                    }
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        quit = true;
                    }
                },
                c.SDL_KEYUP => {
                    for (0..NUM_KEYS) |i| {
                        if (event.key.keysym.sym == KEYMAP[i]) {
                            chip8.keys[i] = false;
                        }
                    }
                },
                c.SDL_QUIT => {
                    quit = true;
                },
                else => {},
            }
        }

        chip8.tick();
        if (chip8.display_updated) {
            _ = c.SDL_RenderClear(renderer);
            for (0..SCREEN_HEIGHT) |y| {
                for (0..SCREEN_WIDTH) |x| {
                    const pixel = chip8.screen[y * SCREEN_WIDTH + x];
                    pixel_buffer[(y * SCREEN_WIDTH) + x] = (@as(u32, 0xFFFFFF00) * @intFromBool(pixel)) | 0x000000FF;
                }
            }
            _ = c.SDL_UpdateTexture(texture, null, @ptrCast(pixel_buffer), SCREEN_WIDTH * @sizeOf(u32));
            _ = c.SDL_RenderCopy(renderer, texture, null, null);
            c.SDL_RenderPresent(renderer);
        }

        c.SDL_Delay(17);
    }
}

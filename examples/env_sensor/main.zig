const std = @import("std");

const sdk = @import("mcu_sdk");

const SerialTerminal = sdk.utils.PciDevice(sdk.SerialTerminal, .serial_terminal);
const EnvSensor = sdk.utils.PciDevice(sdk.EnvSensor, .env_sensor);

const C = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const inv = "\x1b[7m";

    const cyan = "\x1b[36m";
    const bcyan = "\x1b[96m";
    const dcyan = "\x1b[38;5;30m";

    const white = "\x1b[37m";
    const bwhite = "\x1b[97m";
    const black = "\x1b[30m";
    const gray = "\x1b[90m";

    const green = "\x1b[32m";
    const bgreen = "\x1b[92m";
    const red = "\x1b[31m";
    const bred = "\x1b[91m";
    const yellow = "\x1b[33m";
    const byellow = "\x1b[93m";
    const blue = "\x1b[34m";
    const bblue = "\x1b[94m";
    const magenta = "\x1b[35m";
    const bmagenta = "\x1b[95m";
};

const Shell = struct {
    terminal: SerialTerminal,
    sensor: EnvSensor,
    writer: sdk.utils.SerialTerminalWriter,
    out_buffer: [sdk.SerialTerminal.OUTPUT_BUFFER_SIZE]u8,
    read_count: u32,

    pub fn init(terminal: SerialTerminal, sensor: EnvSensor) Shell {
        var shell = Shell{
            .terminal = terminal,
            .sensor = sensor,
            .writer = undefined,
            .out_buffer = undefined,
            .read_count = 0,
        };

        shell.writer = .init(terminal.slot, terminal.mmio(), &shell.out_buffer);

        return shell;
    }

    pub fn run(this: *Shell) void {
        sdk.arch.Mie.setMeie();
        this.terminal.mmio().interrupts().on_new_data = true;
        this.sensor.mmio().config().interrupts.on_ready = true;

        this.printBanner();

        while (true) {
            if (this.terminal.mmio().lastEvent()) |event| {
                this.terminal.mmio().ack();

                if (event.ty == .new_data) {
                    this.handleInput();
                }
            }

            if (this.sensor.mmio().lastEvent()) |event| {
                this.sensor.mmio().ack();

                if (event.ty == .ready) {
                    this.print("\n");
                    this.printBox("SENSOR READY", C.bgreen);
                    this.print(C.green ++ "  ✓ " ++ C.bgreen ++ "New readings available" ++ C.reset ++ "\n\n");
                    this.printPrompt();
                    this.flush();
                }
            }

            sdk.arch.wfi();
        }
    }

    fn printBanner(this: *Shell) void {
        this.print("\n" ++ C.cyan);
        this.print("      ╔═══════════════╗\n");
        this.print("      ║ " ++ C.bcyan ++ "◉" ++ C.cyan ++ " ENV SENSOR " ++ C.bcyan ++ "◉" ++ C.cyan ++ " ║    " ++ C.bold ++ C.bcyan ++ "Environmental Monitor" ++ C.reset ++ "\n");
        this.print(C.cyan ++ "      ╠═══════════════╣    " ++ C.dim ++ "Atmospheric & Radiation" ++ C.reset ++ "\n");
        this.print(C.cyan ++ "      ║ " ++ C.dim ++ "≋≋≋≋≋≋≋≋≋≋≋≋≋" ++ C.reset ++ C.cyan ++ " ║\n");
        this.print("      ║ " ++ C.byellow ++ "☢" ++ C.cyan ++ " " ++ C.dim ++ "RAD" ++ C.reset ++ C.cyan ++ " " ++ C.bgreen ++ "○" ++ C.cyan ++ " " ++ C.dim ++ "ATM" ++ C.reset ++ C.cyan ++ " ║\n");
        this.print("      ╚═══════════════╝\n");
        this.print(C.reset ++ "\n");

        this.printThinBox("Type 'help' for commands");
        this.print("\n");
        this.printPrompt();
        this.flush();
    }

    fn printBox(this: *Shell, title: []const u8, comptime color: []const u8) void {
        this.print(color ++ C.bold ++ "  ┌─ " ++ C.reset);
        this.print(color ++ C.bold);
        this.print(title);
        this.print(" " ++ C.reset);
        this.print(color ++ C.bold ++ "─┐" ++ C.reset ++ "\n");
    }

    fn printThinBox(this: *Shell, text: []const u8) void {
        this.print(C.gray ++ "  ┌");

        for (0..text.len + 2) |_| {
            this.print("─");
        }

        this.print("┐\n");
        this.print("  │ " ++ C.reset ++ C.dim);
        this.print(text);
        this.print(C.gray ++ " │\n");
        this.print("  └");

        for (0..text.len + 2) |_| {
            this.print("─");
        }

        this.print("┘" ++ C.reset ++ "\n");
    }

    fn handleInput(this: *Shell) void {
        const bytes = this.terminal.mmio().len();
        var input_buffer: [sdk.SerialTerminal.INPUT_BUFFER_SIZE]u8 = undefined;
        sdk.dma.read(this.terminal.slot, 0, input_buffer[0..bytes]);

        var input = input_buffer[0..bytes];

        while (input.len > 0 and (input[input.len - 1] == '\n' or input[input.len - 1] == '\r')) {
            input = input[0 .. input.len - 1];
        }

        this.executeCommand(input);
        this.printPrompt();
        this.flush();
    }

    fn executeCommand(this: *Shell, input: []const u8) void {
        var trimmed = input;

        while (trimmed.len > 0 and trimmed[0] == ' ') {
            trimmed = trimmed[1..];
        }

        if (trimmed.len == 0) {
            return;
        }

        var cmd = trimmed;
        var args: []const u8 = "";

        if (std.mem.indexOfScalar(u8, trimmed, ' ')) |idx| {
            cmd = trimmed[0..idx];
            args = trimmed[idx + 1 ..];

            while (args.len > 0 and args[0] == ' ') {
                args = args[1..];
            }
        }

        if (std.mem.eql(u8, cmd, "help")) {
            this.cmdHelp();
        } else if (std.mem.eql(u8, cmd, "read")) {
            this.cmdRead();
        } else if (std.mem.eql(u8, cmd, "atmos")) {
            this.cmdAtmos();
        } else if (std.mem.eql(u8, cmd, "rad")) {
            this.cmdRad();
        } else if (std.mem.eql(u8, cmd, "rays")) {
            this.cmdRays(args);
        } else if (std.mem.eql(u8, cmd, "update")) {
            this.cmdUpdate();
        } else if (std.mem.eql(u8, cmd, "status")) {
            this.cmdStatus();
        } else {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ C.red ++ "Unknown: " ++ C.reset);
            this.print(cmd);
            this.print("\n");
        }
    }

    fn cmdHelp(this: *Shell) void {
        this.print("\n");
        this.printBox("EnvSensor Commands", C.cyan);
        this.print("\n");
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "read" ++ C.gray ++ "          " ++ C.dim ++ "Full sensor readout\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "atmos" ++ C.gray ++ "         " ++ C.dim ++ "Atmospheric data\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "rad" ++ C.gray ++ "           " ++ C.dim ++ "Radiation levels\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "rays " ++ C.gray ++ "<type>   " ++ C.dim ++ "Toggle ray detection\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "update" ++ C.gray ++ "        " ++ C.dim ++ "Request new reading\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "status" ++ C.gray ++ "        " ++ C.dim ++ "Sensor status\n" ++ C.reset);
        this.print(C.bcyan ++ "  > " ++ C.bwhite ++ "help" ++ C.gray ++ "          " ++ C.dim ++ "This screen\n" ++ C.reset);
        this.print("\n");
        this.print(C.gray ++ "  rays: alpha, beta, hawking" ++ C.reset ++ "\n\n");
    }

    fn cmdRead(this: *Shell) void {
        if (!this.sensor.mmio().ready()) {
            this.print(C.byellow ++ "  [~] " ++ C.reset ++ C.dim ++ "Sensor not ready..." ++ C.reset ++ "\n");

            return;
        }

        this.read_count += 1;
        this.cmdAtmos();
        this.cmdRad();
    }

    fn cmdAtmos(this: *Shell) void {
        const atmos = this.sensor.mmio().status().atmos;

        this.print("\n");
        this.print(C.cyan ++ "  ┌────────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.bcyan ++ "    Atmospheric Data   " ++ C.reset ++ C.cyan ++ "│\n");
        this.print("  ├────────────────────────┤\n");

        this.print("  │ " ++ C.gray ++ "Pressure:  " ++ C.reset ++ C.bold ++ C.bwhite);
        this.printNumber(atmos.pressure);
        this.print(C.dim ++ " Pa");
        this.printPaddingWith(atmos.pressure, 8);
        this.print(C.cyan ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Temp:      " ++ C.reset ++ C.bold ++ C.byellow);
        this.printNumber(atmos.temperature);
        this.print(C.dim ++ " K");
        this.printPaddingWith(atmos.temperature, 9);
        this.print(C.cyan ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Moles:     " ++ C.reset ++ C.bwhite);
        this.printNumber(atmos.total_moles);
        this.printPaddingWith(atmos.total_moles, 11);
        this.print(C.cyan ++ "│\n");

        this.print("  ├────────────────────────┤\n");

        this.print("  │ " ++ C.bblue ++ "O2  " ++ C.reset ++ C.gray);
        this.printNumber(atmos.oxygen);
        this.print("  " ++ C.bwhite ++ "N2  " ++ C.reset ++ C.gray);
        this.printNumber(atmos.nitrogen);
        this.printPaddingGas(atmos.oxygen, atmos.nitrogen);
        this.print(C.cyan ++ "│\n");

        this.print("  │ " ++ C.gray ++ "CO2 " ++ C.reset ++ C.gray);
        this.printNumber(atmos.carbon_dioxide);
        this.print("  " ++ C.bcyan ++ "H2  " ++ C.reset ++ C.gray);
        this.printNumber(atmos.hydrogen);
        this.printPaddingGas(atmos.carbon_dioxide, atmos.hydrogen);
        this.print(C.cyan ++ "│\n");

        this.print("  │ " ++ C.bmagenta ++ "Plasma " ++ C.reset ++ C.gray);
        this.printNumber(atmos.plasma);
        this.printPaddingWith(atmos.plasma, 15);
        this.print(C.cyan ++ "│\n");

        this.print("  └────────────────────────┘" ++ C.reset ++ "\n");
    }

    fn cmdRad(this: *Shell) void {
        const rad = this.sensor.mmio().status().radiation;

        this.print("\n");
        this.print(C.yellow ++ "  ┌────────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.byellow ++ "   ☢ Radiation Data ☢  " ++ C.reset ++ C.yellow ++ "│\n");
        this.print("  ├────────────────────────┤\n");

        this.print("  │ " ++ C.gray ++ "Activity:  " ++ C.reset ++ C.bold ++ C.byellow);
        this.printNumber(rad.avg_activity);
        this.print(C.dim ++ " Bq");
        this.printPaddingWith(rad.avg_activity, 7);
        this.print(C.yellow ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Energy:    " ++ C.reset ++ C.bold ++ C.byellow);
        this.printNumber(rad.avg_energy);
        this.print(C.dim ++ " eV");
        this.printPaddingWith(rad.avg_energy, 7);
        this.print(C.yellow ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Dose:      " ++ C.reset ++ C.bold);

        if (rad.dose > 100) {
            this.print(C.bred);
        } else if (rad.dose > 50) {
            this.print(C.byellow);
        } else {
            this.print(C.bgreen);
        }

        this.printNumber(rad.dose);
        this.print(C.dim ++ " Gy");
        this.printPaddingWith(rad.dose, 7);
        this.print(C.yellow ++ "│\n");

        this.print("  └────────────────────────┘" ++ C.reset ++ "\n\n");
    }

    fn cmdRays(this: *Shell, args: []const u8) void {
        if (args.len == 0) {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "Usage: rays <alpha|beta|hawking>\n");
            this.printRaysStatus();

            return;
        }

        var ray_type = args;

        if (std.mem.indexOfScalar(u8, args, ' ')) |idx| {
            ray_type = args[0..idx];
        }

        const rays = this.sensor.mmio().config().rays;

        if (std.mem.eql(u8, ray_type, "alpha")) {
            this.sensor.mmio().config().rays.alpha = !rays.alpha;
            this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Alpha rays: ");

            if (!rays.alpha) {
                this.print(C.bgreen ++ "ON\n" ++ C.reset);
            } else {
                this.print(C.bred ++ "OFF\n" ++ C.reset);
            }
        } else if (std.mem.eql(u8, ray_type, "beta")) {
            this.sensor.mmio().config().rays.beta = !rays.beta;
            this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Beta rays: ");

            if (!rays.beta) {
                this.print(C.bgreen ++ "ON\n" ++ C.reset);
            } else {
                this.print(C.bred ++ "OFF\n" ++ C.reset);
            }
        } else if (std.mem.eql(u8, ray_type, "hawking")) {
            this.sensor.mmio().config().rays.hawking = !rays.hawking;
            this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Hawking radiation: ");

            if (!rays.hawking) {
                this.print(C.bgreen ++ "ON\n" ++ C.reset);
            } else {
                this.print(C.bred ++ "OFF\n" ++ C.reset);
            }
        } else {
            this.print(C.bred ++ "  [!] " ++ C.reset ++ "Unknown ray type: ");
            this.print(ray_type);
            this.print("\n");
        }
    }

    fn printRaysStatus(this: *Shell) void {
        const rays = this.sensor.mmio().config().rays;

        this.print(C.gray ++ "  Current: " ++ C.reset);
        this.print("a:");

        if (rays.alpha) {
            this.print(C.bgreen ++ "ON " ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF " ++ C.reset);
        }

        this.print("b:");

        if (rays.beta) {
            this.print(C.bgreen ++ "ON " ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF " ++ C.reset);
        }

        this.print("H:");

        if (rays.hawking) {
            this.print(C.bgreen ++ "ON" ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset);
        }

        this.print("\n");
    }

    fn cmdUpdate(this: *Shell) void {
        if (!this.sensor.mmio().ready()) {
            this.print(C.byellow ++ "  [~] " ++ C.reset ++ C.dim ++ "Sensor busy..." ++ C.reset ++ "\n");

            return;
        }

        this.sensor.mmio().action().update = 1;
        this.print(C.bgreen ++ "  [+] " ++ C.reset ++ "Update requested\n");
    }

    fn cmdStatus(this: *Shell) void {
        this.print("\n");
        this.print(C.cyan ++ "  ┌──────────────────────┐\n");
        this.print("  │" ++ C.bold ++ C.bcyan ++ "    Sensor Status    " ++ C.reset ++ C.cyan ++ "│\n");
        this.print("  ├──────────────────────┤\n");

        this.print("  │ " ++ C.gray ++ "Ready: " ++ C.reset);

        if (this.sensor.mmio().ready()) {
            this.print(C.bgreen ++ "YES          " ++ C.reset);
        } else {
            this.print(C.byellow ++ "NO           " ++ C.reset);
        }

        this.print(C.cyan ++ "│\n");

        this.print("  │ " ++ C.gray ++ "Reads: " ++ C.reset ++ C.bwhite);
        this.printNumber(this.read_count);
        this.printPadding(this.read_count);
        this.print(C.cyan ++ "│\n");

        this.print("  ├──────────────────────┤\n");
        this.print("  │ " ++ C.gray ++ "Ray Detection:" ++ C.reset ++ "       " ++ C.cyan ++ "│\n");

        const rays = this.sensor.mmio().config().rays;

        this.print("  │   " ++ C.gray ++ "Alpha:   ");

        if (rays.alpha) {
            this.print(C.bgreen ++ "ON " ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset);
        }

        this.print("        " ++ C.cyan ++ "│\n");

        this.print("  │   " ++ C.gray ++ "Beta:    ");

        if (rays.beta) {
            this.print(C.bgreen ++ "ON " ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset);
        }

        this.print("        " ++ C.cyan ++ "│\n");

        this.print("  │   " ++ C.gray ++ "Hawking: ");

        if (rays.hawking) {
            this.print(C.bgreen ++ "ON " ++ C.reset);
        } else {
            this.print(C.bred ++ "OFF" ++ C.reset);
        }

        this.print("        " ++ C.cyan ++ "│\n");

        this.print("  └──────────────────────┘" ++ C.reset ++ "\n\n");
    }

    fn printPadding(this: *Shell, n: anytype) void {
        const val: u32 = @intCast(n);
        const digits: u32 = if (val == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        var i: u32 = 0;
        while (i < 13 - digits) : (i += 1) {
            this.print(" ");
        }

        this.print(C.reset);
    }

    fn printPaddingWith(this: *Shell, n: anytype, offset: u32) void {
        const val: u32 = @intCast(n);
        const digits: u32 = if (val == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        var i: u32 = 0;
        while (i < 22 - offset - digits) : (i += 1) {
            this.print(" ");
        }

        this.print(C.reset);
    }

    fn printPaddingGas(this: *Shell, n1: anytype, n2: anytype) void {
        const val1: u32 = @intCast(n1);
        const val2: u32 = @intCast(n2);

        const digits1: u32 = if (val1 == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val1;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        const digits2: u32 = if (val2 == 0) 1 else blk: {
            var d: u32 = 0;
            var v = val2;
            while (v > 0) : (v /= 10) d += 1;
            break :blk d;
        };

        var i: u32 = 0;
        while (i < 10 - digits1 - digits2) : (i += 1) {
            this.print(" ");
        }

        this.print(C.reset);
    }

    inline fn printPrompt(this: *Shell) void {
        this.print(C.cyan ++ "env" ++ C.bcyan ++ ":sensor" ++ C.bwhite ++ "$ " ++ C.reset);
    }

    inline fn print(this: *Shell, text: []const u8) void {
        this.writer.interface.writeAll(text) catch {};
    }

    inline fn printFmt(this: *Shell, comptime fmt: []const u8, args: anytype) void {
        this.writer.interface.print(fmt, args) catch {};
    }

    inline fn printNumber(this: *Shell, n: anytype) void {
        this.writer.interface.print("{}", .{n}) catch {};
    }

    inline fn flush(this: *Shell) void {
        this.writer.flush() catch {};
    }
};

pub fn main() void {
    const terminal = SerialTerminal.find() orelse return;
    const sensor = EnvSensor.find() orelse return;

    var shell = Shell.init(terminal, sensor);
    shell.run();
}

comptime {
    _ = sdk.utils.EntryPoint(.{
        .stack_size = std.math.pow(u32, 2, 14),
    });
}

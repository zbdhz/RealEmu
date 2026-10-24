// Legacy OFDM, 20 MHz. PSDU length includes FCS; SERVICE+tail = 22 bits.
// Constant divisors synthesize to multiply/shift networks, never a run-time
// general divider. Callers register symbols before converting to cycles.
import Types::*;

function UInt#(20) ofdmSymbols(MpduLen length, Mcs mcs);
    UInt#(20) bits = (zeroExtend(unpack(length)) << 3) + 22;
    case (mcs)
        0: return (bits + 23) / 24;
        1: return (bits + 35) / 36;
        2: return (bits + 47) / 48;
        3: return (bits + 71) / 72;
        4: return (bits + 95) / 96;
        5: return (bits + 143) / 144;
        6: return (bits + 191) / 192;
        7: return (bits + 215) / 216;
        default: return (bits + 23) / 24;
    endcase
endfunction

function UInt#(32) symbolsToCycles(UInt#(20) symbols);
    return (20 + (zeroExtend(symbols) << 2)) * fromInteger(valueOf(US_CYCLES));
endfunction

function UInt#(32) frameTimeUs(MpduLen length, Mcs mcs);
    return 20 + (zeroExtend(ofdmSymbols(length, mcs)) << 2);
endfunction

// Duration/ID bit 15 must remain zero. Very long reservations saturate.
function Duration reservation(UInt#(32) us);
    return us > 32767 ? 32767 : truncate(pack(us));
endfunction

function Duration dataDuration(MacConfig cfg);
    return reservation(zeroExtend(unpack(cfg.sifs)) + frameTimeUs(14, cfg.controlMcs));
endfunction

function Duration rtsDuration(MacEvent frame, MacConfig cfg);
    return reservation(3 * zeroExtend(unpack(cfg.sifs)) +
        2 * frameTimeUs(14, cfg.controlMcs) + frameTimeUs(frame.mpduDigest.length, frame.rfParam.mcs));
endfunction

function Duration ctsDuration(Duration rts, MacConfig cfg);
    UInt#(32) subtract = zeroExtend(unpack(cfg.sifs)) + frameTimeUs(14, cfg.controlMcs);
    UInt#(32) duration = zeroExtend(unpack(rts));
    return duration > subtract ? reservation(duration - subtract) : 0;
endfunction

// Modular clock comparisons are valid for intervals shorter than 2^31 cycles.
function Bool timeReached(UInt#(32) now, UInt#(32) deadline);
    Int#(32) delta = unpack(pack(now - deadline));
    return delta >= 0;
endfunction

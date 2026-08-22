function run_matlab_tests()
    % 当前协议与调制参数的无硬件回归测试。
    project_setup();

    infoCfg = get_gfsk_source_config("red_broadcast");
    jammerCfg = get_gfsk_source_config("red_l1_jammer");
    assert(infoCfg.Fs == 1e6 && infoCfg.sps == 47 && infoCfg.bt == 0.35);
    assert(infoCfg.dataPushRateBytesPerSec == 1400);
    assert(jammerCfg.dataPushRateBytesPerSec == 1350);

    infoCycle = get_source_protocol_cycle(infoCfg);
    assert(infoCycle.payloadBytesPerCycle == 140);
    assert(infoCycle.protocolFrameCountPerCycle == 5);
    expectedCmdIds = uint16([hex2dec('0A01'), hex2dec('0A02'), hex2dec('0A03'), hex2dec('0A04'), hex2dec('0A05')]);
    assert(all([infoCycle.protocolFrames.cmdId] == expectedCmdIds));

    jammerCycle = get_source_protocol_cycle(jammerCfg, "abcdef");
    assert(jammerCycle.payloadBytesPerCycle == 135);
    frameHex = upper(join(compose("%02X", jammerCycle.protocolFrames(1).frameBytes), ""));
    assert(frameHex == "A506000791060A61626364656616E2");

    sourceNames = [ ...
        "red_broadcast", "red_l1_jammer", "red_l2_jammer", "red_l3_jammer", ...
        "blue_broadcast", "blue_l1_jammer", "blue_l2_jammer", "blue_l3_jammer"];
    for sourceName = sourceNames
        cfg = get_gfsk_source_config(sourceName);
        cycleSpec = get_source_protocol_cycle(cfg);
        packet1 = cycleSpec.otaSpec.packets(1).packetBytes;
        packet2 = cycleSpec.otaSpec.packets(2).packetBytes;
        bits1 = logical(bytes_to_bits_msb(packet1));
        bits2 = logical(bytes_to_bits_msb(packet2));
        symbolMetrics = 2 * double([false(4, 1); bits1(:); false; bits2(:)]) - 1;
        decoded = decode_gfsk_symbol_stream(symbolMetrics, build_gfsk_rx_reference(sourceName));
        assert(decoded.validPacketCount == 2);
        assert(decoded.accessAlignmentCount == 2);
    end

    fprintf("MATLAB 当前协议回归测试通过。\n");
end

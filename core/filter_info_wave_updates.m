function [state, accepted, duplicateDrops, staleDrops] = ...
        filter_info_wave_updates(state, updates, windowEndSample)
    % 一个250 ms窗口可能包含同一命令的两三轮数据，只保留该窗口最后一帧。
    % 相邻重叠窗口再次解析到相同 seq+payload 时视为同一物理帧，不刷新fresh。
    % 两个worker乱序返回时，较旧窗口不得回写已经处理过的新窗口。
    accepted = updates([]);
    duplicateDrops = 0;
    staleDrops = 0;
    if isempty(updates)
        return;
    end

    keep = false(numel(updates), 1);
    seenCmd = false(5, 1);
    for updateIdx = numel(updates):-1:1
        cmdIndex = updates(updateIdx).index;
        if cmdIndex >= 1 && cmdIndex <= 5 && ~seenCmd(cmdIndex)
            keep(updateIdx) = true;
            seenCmd(cmdIndex) = true;
        end
    end
    candidates = updates(keep);
    offsets = [1, 25, 37, 47, 55];
    lengths = [24, 12, 10, 8, 41];

    for updateIdx = 1:numel(candidates)
        update = candidates(updateIdx);
        cmdIndex = update.index;
        if windowEndSample < state.infoCmdProcessedWindowEnd(cmdIndex)
            staleDrops = staleDrops + 1;
            state.infoStaleWindowDropCount = ...
                state.infoStaleWindowDropCount + 1;
            continue;
        end

        state.infoCmdProcessedWindowEnd(cmdIndex) = windowEndSample;
        offset = offsets(cmdIndex);
        payloadLength = lengths(cmdIndex);
        cachedPayload = state.infoCmdPayloads( ...
            offset:offset + payloadLength - 1);
        sameIdentity = state.infoCmdHasIdentity(cmdIndex) && ...
            state.infoCmdLastAcceptedSeq(cmdIndex) == uint8(update.seq) && ...
            isequal(uint8(cachedPayload(:)), uint8(update.dataBytes(:)));
        if sameIdentity
            duplicateDrops = duplicateDrops + 1;
            state.infoDuplicateDropCount = state.infoDuplicateDropCount + 1;
            continue;
        end

        state.infoCmdHasIdentity(cmdIndex) = true;
        state.infoCmdLastAcceptedSeq(cmdIndex) = uint8(update.seq);
        accepted(end+1) = update; %#ok<AGROW>
    end
end

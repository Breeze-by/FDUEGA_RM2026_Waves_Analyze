function cleanup_pluto_workspace_objects()
    release_if_exists('tx');
    release_if_exists('rx');
end

function release_if_exists(varName)
    existsInBase = evalin('base', sprintf("exist('%s','var')", varName));
    if ~existsInBase
        return;
    end

    try
        obj = evalin('base', varName);
        if isobject(obj)
            try
                release(obj);
            catch
            end
        end
    catch
    end

    evalin('base', sprintf('clear %s', varName));
end

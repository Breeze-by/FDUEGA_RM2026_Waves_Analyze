function rootDir = project_setup()
    rootDir = fileparts(mfilename('fullpath'));

    dirs = {
        rootDir
        fullfile(rootDir, 'config')
        fullfile(rootDir, 'core')
        fullfile(rootDir, 'utils')
        fullfile(rootDir, 'CRC')
        fullfile(rootDir, 'math')
        fullfile(rootDir, 'protocol')
        fullfile(rootDir, 'project_book')
    };

    for k = 1:numel(dirs)
        if exist(dirs{k}, 'dir') == 7
            addpath(dirs{k});
        end
    end
end

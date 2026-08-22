function [fAxis, magDb] = simple_spectrum_db(x, Fs, Nfft)
    x = x(:);
    if nargin < 3
        Nfft = 8192;
    end

    xw = x(1:min(numel(x), Nfft));
    if numel(xw) < Nfft
        xw(end+1:Nfft) = 0;
    end

    w = hann(Nfft);
    X = fftshift(fft(xw .* w, Nfft));
    mag = abs(X);
    mag = mag / max(mag + eps);
    magDb = 20*log10(mag + 1e-12);

    fAxis = (-Nfft/2:Nfft/2-1).' / Nfft * Fs;
end

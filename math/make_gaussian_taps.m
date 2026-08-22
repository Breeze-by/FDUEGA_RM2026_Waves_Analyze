function h = make_gaussian_taps(bt, span, sps)
    if exist('gaussdesign', 'file') == 2
        h = gaussdesign(bt, span, sps);
    else
        t = (-span/2 : 1/sps : span/2).';
        alpha = sqrt(log(2) / 2) / bt;
        h = (sqrt(pi) / alpha) * exp(-(pi * t / alpha).^2);
    end

    h = h(:);
    h = h / sum(h);
end


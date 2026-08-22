function fHat = fsk_discriminator_hz(samples, sampleRateHz)
    samples = samples(:);
    phaseDifference = angle(samples(2:end) .* conj(samples(1:end-1)));
    fHat = real(phaseDifference * sampleRateHz / (2*pi));
end

% Reference fits of the seven psychometric functions by the original Palamedes toolbox
% (Prins & Kingdom, palamedestoolbox.org), which the suite compares PEM's fit with
% (test_analytics.jl, "The fit agrees with the Palamedes toolbox"). Run under Octave or
% MATLAB from this directory, with the toolbox on the path:
%
%   octave --eval "addpath('<...>/Palamedes'); palamedes_fit"
%
% It writes palamedes_fit.csv, one fit per row: the function's name, whether the lapse
% rate was free (within [0, 0.06]) or held at 0, gamma, the number of levels, the
% toolbox's alpha, beta, lambda, log likelihood and scenario (1: a fit; negative: a step
% or a constant function), then 9 levels, 9 counts of positive answers and 9 counts of
% answers, each padded with NaN. Every dataset is fitted by all seven functions, both
% ways.
%
% The search grid is the one PEM starts from: thresholds within half the levels' span of
% them and slopes from a curve ten times wider than the span to one rising over a twelfth
% of the smallest gap, on the axis the function is a location-scale family of (the
% logarithm of the level for the Weibull and the Quick), scaled by how steep the
% function's standard form is.

rand('twister', 20261118);
pad = @(v) [v nan(1, 9 - numel(v))];
answers = [8 20 40];
names = {'logistic', 'cumulative_normal', 'hyperbolic_secant', 'gumbel', 'log_quick', ...
         'weibull', 'quick'};
functions = {@PAL_Logistic, @PAL_CumulativeNormal, @PAL_HyperbolicSecant, @PAL_Gumbel, ...
             @PAL_logQuick, @PAL_Weibull, @PAL_Quick};
% The steepest rise of each standard form, relative to the logistic's 1/4
steepness = [1, 4 / sqrt(2 * pi), 2, 4 * log(10) / exp(1), 4 * log(10) / exp(1), ...
             4 / exp(1), 4 / exp(1)];
on_log_axis = [false false false false false true true];

out = fopen('palamedes_fit.csv', 'w');
for i = 1:200
    scale = 10 ^ (randi(6) - 3);                 % a step between levels of 0.01 to 1000
    nLevels = randi([4 9]);
    levels = scale * (1:nLevels) + scale * 50 * (rand < 0.5);
    gamma = 0.5 * (rand < 0.5);
    lapse = 0.03 * (rand < 0.5);
    span = levels(end) - levels(1);
    alpha = levels(1) + span * (0.2 + 0.6 * rand);
    beta = (0.5 + 4 * rand) / scale;
    n = answers(randi(3));
    p = PAL_Logistic([alpha beta gamma lapse], levels);
    numPos = sum(rand(n, nLevels) < repmat(p, n, 1), 1);
    outOfNum = n * ones(1, nLevels);

    for m = 1:numel(names)
        if on_log_axis(m)
            axis = log(levels);
        else
            axis = levels;
        end
        width = axis(end) - axis(1);
        gap = min(diff(axis));
        centres = linspace(axis(1) - width / 2, axis(end) + width / 2, 41);
        if on_log_axis(m)
            centres = exp(centres);
        end
        searchGrid.alpha = centres;
        searchGrid.beta = logspace(log10(0.4 / width / steepness(m)), ...
                                   log10(12 / gap / steepness(m)), 24);
        searchGrid.gamma = gamma;
        for free = 0:1
            if free
                searchGrid.lambda = [0 0.02 0.04 0.06];
                [params, LL, scenario] = PAL_PFML_Fit(levels, numPos, outOfNum, searchGrid, ...
                    [1 1 0 1], functions{m}, 'lapseLimits', [0 0.06]);
            else
                searchGrid.lambda = 0;
                [params, LL, scenario] = PAL_PFML_Fit(levels, numPos, outOfNum, searchGrid, ...
                    [1 1 0 0], functions{m});
            end
            fprintf(out, '%s,%d', names{m}, free);
            fprintf(out, ',%.17g', [gamma nLevels params(1) params(2) params(4) LL scenario ...
                                    pad(levels) pad(numPos) pad(outOfNum)]);
            fprintf(out, '\n');
        end
    end
end
fclose(out);

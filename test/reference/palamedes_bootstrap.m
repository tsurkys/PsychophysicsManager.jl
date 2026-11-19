% Reference parametric bootstraps by the original Palamedes toolbox (Prins & Kingdom,
% palamedestoolbox.org, PAL_PFML_BootstrapParametric), whose standard errors the suite
% compares PEM's with (test_analytics.jl, "The bootstrap agrees with the Palamedes
% toolbox"). Run under Octave or MATLAB from this directory, with the toolbox on the path:
%
%   octave --eval "addpath('<...>/Palamedes'); palamedes_bootstrap"
%
% It writes palamedes_bootstrap.csv, one dataset per row: the function's name, whether the
% lapse rate was free (within [0, 0.06]), gamma, the number of simulations, the standard
% errors of alpha and beta, how many simulations converged, the number of levels, then
% the levels, the counts of positive answers and the counts of answers.

rand('twister', 20261118);
B = 4000;
%            name                 free gamma levels                        positive                      answers
datasets = {'logistic',           0,   0.5,  1:6,                          [21 24 29 35 38 40],          40;
            'weibull',            0,   0.5,  [0.05 0.1 0.15 0.2 0.25 0.3], [22 25 31 36 39 40],          40;
            'cumulative_normal',  0,   0,    -3:3,                         [1 3 8 15 22 27 29],          30;
            'gumbel',             1,   0.5,  -2:0.25:-0.5,                 [20 22 27 33 37 39 39],       40};
functions = struct('logistic', @PAL_Logistic, 'cumulative_normal', @PAL_CumulativeNormal, ...
                   'gumbel', @PAL_Gumbel, 'weibull', @PAL_Weibull);

out = fopen('palamedes_bootstrap.csv', 'w');
for d = 1:size(datasets, 1)
    [name, free, gamma, levels, numPos, n] = datasets{d, :};
    PF = functions.(name);
    outOfNum = n * ones(size(levels));
    if strcmp(name, 'weibull')
        searchGrid.alpha = exp(linspace(log(levels(1)) - 1, log(levels(end)) + 1, 41));
        searchGrid.beta = logspace(-1, 2, 24);
    else
        span = levels(end) - levels(1);
        searchGrid.alpha = linspace(levels(1) - span / 2, levels(end) + span / 2, 41);
        searchGrid.beta = logspace(log10(0.1 / span), log10(20 / min(diff(levels))), 24);
    end
    searchGrid.gamma = gamma;
    if free
        searchGrid.lambda = [0 0.02 0.04 0.06];
        options = {'lapseLimits', [0 0.06]};
    else
        searchGrid.lambda = 0;
        options = {};
    end
    paramsFree = [1 1 0 free];
    params = PAL_PFML_Fit(levels, numPos, outOfNum, searchGrid, paramsFree, PF, options{:});
    [SD, paramsSim, LLSim, converged] = PAL_PFML_BootstrapParametric(levels, outOfNum, ...
        params, paramsFree, B, PF, 'searchGrid', searchGrid, options{:});
    fprintf(out, '%s,%d', name, free);
    fprintf(out, ',%.17g', [gamma B SD(1) SD(2) sum(converged) numel(levels) levels numPos ...
                            outOfNum]);
    fprintf(out, '\n');
end
fclose(out);

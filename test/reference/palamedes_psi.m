% Reference runs of the Psi method by the original Palamedes toolbox (Prins & Kingdom,
% palamedestoolbox.org, PAL_AMPM_setupPM and PAL_AMPM_updatePM), which the suite replays
% through PEM's Psi (test_psi.jl, "Psi agrees with the Palamedes toolbox"). Run under
% Octave or MATLAB from this directory, with the toolbox on the path:
%
%   octave --eval "addpath('<...>/Palamedes'); palamedes_psi"
%
% A simulated observer answers each level the toolbox chooses. It writes two tables:
%
% palamedes_psi_runs.csv, one run per row: the function's name, gamma, lambda, the
%   stimulus, threshold and log10-slope grids as first, last and number of points
%   (linspace), the number of trials, and the first level the toolbox chose.
% palamedes_psi_trials.csv, one trial per row: the run's row number, the trial, the level
%   presented, the answer (1 or 0), the posterior mean threshold and log10 slope after it,
%   the threshold's posterior standard deviation, and the level chosen next.

rand('twister', 20261118);
%        name                 gamma lambda  stim grid        alpha grid         beta grid       trials  observer alpha, log10 beta
runs = {'gumbel',             0.5,  0.02,  [-2 0 21],       [-2 0 21],         [-1 1 41],       50,     [-1.1 0.5];
        'logistic',           0.02, 0.02,  [-3 3 25],       [-3 3 25],         [-1 1 41],       40,     [0.4 0.2];
        'weibull',            0.5,  0.02,  [0.01 0.3 30],   [0.01 0.3 30],     [-1 1 41],       50,     [0.12 0.5];
        'cumulative_normal',  0,    0.02,  [-5 5 21],       [-5 5 21],         [-1.5 0.5 21],   40,     [1.2 -0.1];
        'quick',              0.25, 0.03,  [1 40 40],       [1 40 40],         [-0.5 1 31],     45,     [15 0.4];
        'hyperbolic_secant',  0.5,  0.02,  [-1 1 21],       [-1.5 1.5 31],     [-1 1 41],       40,     [0.3 0.6];
        'log_quick',          0.5,  0.01,  [-3 -1 21],      [-3 -1 21],        [0 1.5 31],      40,     [-2.2 0.7]};
functions = struct('logistic', @PAL_Logistic, 'cumulative_normal', @PAL_CumulativeNormal, ...
                   'hyperbolic_secant', @PAL_HyperbolicSecant, 'gumbel', @PAL_Gumbel, ...
                   'log_quick', @PAL_logQuick, 'weibull', @PAL_Weibull, 'quick', @PAL_Quick);
grid = @(g) linspace(g(1), g(2), g(3));

run_table = fopen('palamedes_psi_runs.csv', 'w');
trial_table = fopen('palamedes_psi_trials.csv', 'w');
for r = 1:size(runs, 1)
    [name, gamma, lambda, stim, alphas, betas, trials, observer] = runs{r, :};
    PF = functions.(name);
    PM = PAL_AMPM_setupPM('priorAlphaRange', grid(alphas), 'priorBetaRange', grid(betas), ...
                          'priorGammaRange', gamma, 'priorLambdaRange', lambda, ...
                          'stimRange', grid(stim), 'numTrials', trials, 'PF', PF);
    fprintf(run_table, '%s', name);
    fprintf(run_table, ',%.17g', [gamma lambda stim alphas betas trials PM.xCurrent]);
    fprintf(run_table, '\n');
    for t = 1:trials
        x = PM.xCurrent;
        response = rand < PF([observer(1) 10 ^ observer(2) gamma lambda], x);
        PM = PAL_AMPM_updatePM(PM, response);
        fprintf(trial_table, '%.17g,', [r t x response PM.threshold(t) PM.slope(t) ...
                                        PM.seThreshold(t)]);
        fprintf(trial_table, '%.17g\n', PM.xCurrent);
    end
end
fclose(run_table);
fclose(trial_table);

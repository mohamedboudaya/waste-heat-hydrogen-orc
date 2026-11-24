%% HRES: Rankine cycle (ORC) + PEM electrolyzer -- time-domain simulation
% Single script: builds the residential load profile, runs the Simscape
% model, and computes/plots power balance, hydrogen production, energy
% fluxes and the ORC cycle performance.
%
% Model: HRES_ORC_PEM.slx -- ORC with R1233zd(E) (heat-recovery exchanger,
% variable-nozzle turbine, condenser, liquid receiver, exhaust bypass and three
% PI loops: speed, pressure, superheat), generator, residential load and PEM
% electrolyzer with H2 storage. Design values are stored in the model workspace.
%
% Load data: LoadProfileGenerator (LPG), Pflugradt et al. (2022), JOSS 7(71),
% 3574, https://doi.org/10.21105/joss.03574 -- 4 households, 15-min
% resolution, April 2020 (folder ./data). The households are summed and
% scaled so that the peak load equals the 7 kW design peak of the model.
%
% Usage: set the current folder to /matlab and run this script.
%        Change n_days / start_hour below to simulate another period (default:
%        1 week from Wednesday 1 April 2020, 00:00; about 20 min of computing time).
clear; clc; close all;

n_days    = 7;                          % simulated days (fractions allowed, e.g. 0.25 = 6 h)
start_hour = 0;                         % start of the load profile [h after 1 April 2020, 00:00]
modelName = 'HRES_ORC_PEM';             % Simulink-Simscape model
P_peak    = 7000;                       % [W] peak of the scaled load profile

%% 1. Hydrogen gas property tables (used by the Simscape gas domain)
T_vect    = ([-75 -50 -25 0 25 50 75 100] + 273.15)';          % [K]
h_vect    = [2532 2875 3224 3578 3936 4295 4655 5017]';         % [kJ/kg]
nu_vect   = [6.77 7.34 7.88 8.42 8.94 9.44 9.93 10.41]';        % [uPa s]
cond_vect = [132.4 146.8 160.5 173.4 185.6 197.5 210.1 222.0]'; % [mW/(m K)]
cp_vect   = [13.57 13.87 14.08 14.23 14.33 14.4 14.45 14.47]';  % [kJ/(kg K)]
R_h2      = 4.12;                                               % [kJ/(kg K)]

%% 2. Residential load profile (LoadProfileGenerator data)
files = dir(fullfile('data', 'household_*.mat'));
P = 0;
for k = 1:numel(files)
    S = load(fullfile('data', files(k).name), 'P_HC');   % [kW], 15-min values
    P = P + double(S.P_HC(:));
end
n_pts  = round(n_days*96) + 1;                  % 15-min points
i0     = round(start_hour*4) + 1;               % first point
P_load_profile = P(i0:i0+n_pts-1) * 1000;       % [W]
P_load_profile = P_load_profile * P_peak / (1000*max(P(1:7*96+1)));   % same scaling as the 1-week run
P_load_profile(1) = 0;                          % start with no load connected
LOAD_P = [(0:n_pts-1)' * 900, P_load_profile];  % [t (s), P (W)] -> LOAD subsystem
% Waste heat fluctuation: the industrial process runs at full load on weekdays 06:00-22:00
% (5 kg/s of exhaust at 700 K) and at 70 % at night and at the weekend (3.5 kg/s).
t15  = (0:n_pts-1)' * 900;  hr_abs = start_hour + t15/3600;    % hours from 1 April 2020, 00:00
hr   = mod(hr_abs, 24);  wday = mod(floor(hr_abs/24) + 2, 7);  % 1 April 2020 = Wednesday (0 = Monday)
EXH_AVAIL = [t15, 3.5 + 1.5*(hr >= 6 & hr < 22 & wday <= 4)];  % [t (s), kg/s] -> ORC subsystem
fprintf('Load profile: %d households, %.2f days, peak %.1f kW, mean %.2f kW\n', ...
    numel(files), n_days, max(P_load_profile)/1e3, mean(P_load_profile)/1e3);

%% 3. Model
if ~exist([modelName '.slx'], 'file'), error('%s.slx not found: run this script from the matlab folder.', modelName); end
t_stop = round(n_days * 86400);                  % [s]
fprintf('Running %s for %.2f days (%d s)...\n', modelName, n_days, t_stop);
fprintf('(solver messages are hidden and summarized at the end)\n');
tic;
% evalc captures the solver messages instead of printing them repeatedly
simLog = evalc(['simOut = sim(modelName, ''StopTime'', num2str(t_stop), ' ...
                '''ReturnWorkspaceOutputs'', ''on'', ''CaptureErrors'', ''on'');']);
fprintf('Simulation finished in %.1f min\n', toc/60);
if ~isempty(simOut.ErrorMessage)                 % keep what was simulated before an error
    fprintf(2, 'Simulation stopped early: %s\n', strtok(simOut.ErrorMessage, newline));
    t_stop = floor(simOut.tout(end)/60)*60;  n_days = t_stop/86400;
end

% Summary of the solver messages (numerical, they do not stop the run)
msgTypes = {'encountering difficulty',       'solver difficulty (small step size)'; ...
            'unable to reduce the step size', 'minimum step size reached'; ...
            'zero crossing',                  'zero-crossing notices'; ...
            'fully vapor',                    'turbine inlet not fully vapor'; ...
            'fully liquid',                   'pump inlet not fully liquid'; ...
            'dimensionally incompatible',     'signal unit label mismatch'};
nWarn = count(simLog, 'Warning:');
fprintf('Solver messages during the run: %d\n', nWarn);
for k = 1:size(msgTypes, 1)
    n = count(simLog, msgTypes{k,1});
    if n > 0, fprintf('  - %-42s %d\n', msgTypes{k,2}, n); end
end

%% 5. Post-processing (1-min resolution)
time     = (0:60:t_stop)';
P_gen    = getSignal(simOut, 'P_gen',         time);     % [W]
P_load   = getSignal(simOut, 'P_load',        time);     % [W]
I_elec   = getSignal(simOut, 'I_elec',        time);     % [A]
mdot_g_s = getSignal(simOut, 'H2_cumulative', time);     % H2 mass flow [g/s]
% (the To Workspace block "H2_cumulative" logs the H2 mass FLOW in g/s)
m_dot_H2 = max(mdot_g_s, 0) / 1000;                      % [kg/s]
H2_cum   = cumtrapz(time, m_dot_H2);                     % [kg]
P_elec   = max(P_gen - P_load, 0);                       % surplus to electrolyzer [W]

n_cells = 30;  A_cell = 200;                             % electrolyzer block: 30 cells, 200 cm2
F = 96485;  M_H2 = 2.016e-3;  LHV = 33.33;  HHV = 39.41; % [C/mol], [kg/mol], [kWh/kg]
H2_faraday = trapz(time, n_cells * max(I_elec,0) * M_H2 / (2*F));

kWh   = @(Pw) trapz(time, Pw) / 3.6e6;
E_gen = kWh(P_gen);  E_load = kWh(min(P_load, P_gen));  E_elec = kWh(P_elec);
m_H2  = H2_cum(end); E_H2 = m_H2 * LHV;

fprintf('\n=== RESULTS (%.2f days) ===\n', n_days);
fprintf('Generator           : %7.1f kWh   (max %.1f kW)\n', E_gen, max(P_gen)/1e3);
fprintf('Load                : %7.1f kWh   (max %.1f kW)\n', E_load, max(P_load)/1e3);
fprintf('To electrolyzer     : %7.1f kWh\n', E_elec);
fprintf('Hydrogen            : %7.3f kg    (%.1f kWh LHV, Faraday: %.3f kg)\n', m_H2, E_H2, H2_faraday);
fprintf('Stack losses        : %7.1f kWh\n', E_elec - E_H2);
fprintf('Max stack current   : %7.0f A     (%.2f A/cm2)\n', max(I_elec), max(I_elec)/A_cell);
fprintf('Specific energy     : %7.1f kWh/kg\n', E_elec / m_H2);
fprintf('Electrolyzer effic. : %7.1f %% (LHV) / %.1f %% (HHV)\n', 100*E_H2/E_elec, 100*m_H2*HHV/E_elec);
fprintf('\nHydrogen per day:\n');
for d = 1:floor(n_days)
    k = time >= (d-1)*86400 & time <= d*86400;
    fprintf('  day %d (%s): %.3f kg\n', d, datestr(datenum(2020,4,d), 'ddd dd mmm'), ...
        trapz(time(k), m_dot_H2(k)));
end

%% 6. ORC cycle (state 1 pump inlet, 2 pump outlet, 3 turbine inlet, 4 turbine outlet)
mws  = get_param(modelName, 'ModelWorkspace'); ORC_Taux_val = mws.getVariable('ORC_Taux');
m_wf = getSignal(simOut, 'ORC_mwf', time);               % working-fluid flow [kg/s]
m_gs = getSignal(simOut, 'ORC_mgas', time);              % exhaust through the exchanger [kg/s]
m_ex = getSignal(simOut, 'ORC_mexh', time);              % exhaust available (plant schedule) [kg/s]
w_sh = getSignal(simOut, 'ORC_w', time);                 % shaft speed [rad/s]
for i = 1:4
    h(:,i) = getSignal(simOut, sprintf('h%d',i), time);  % [kJ/kg]
    T(:,i) = getSignal(simOut, sprintf('T%d',i), time);  % [K]
    p(:,i) = getSignal(simOut, sprintf('P%d',i), time);  % [Pa]
end
kWhq  = @(x) trapz(time, x) / 3600;                      % kW -> kWh
% shaft work from the electrical side: generator + mechanical losses (bearings, seals)
E_aux  = trapz(time, -ORC_Taux_val * w_sh .* (time > 1000)) / 3.6e6;  % [kWh]
W_turb = (E_gen + E_aux) / 0.9;                          % turbine work on the fluid (mech. efficiency 0.9)
% cycle states give the split between heat and work (flow-weighted)
w_p   = max(p(:,2) - p(:,1), 0) / 1250 / 1000;           % pump work per kg [kJ/kg] (liquid ~1250 kg/m3)
q_in  = sum(m_wf .* (h(:,3) - h(:,2)));                  % proportional to the heat absorbed
w_t   = sum(m_wf .* (h(:,3) - h(:,4)));                  % proportional to the turbine work
eta_orc = (w_t - sum(m_wf .* w_p)) / q_in;               % ORC thermal efficiency
Q_in  = W_turb * q_in / w_t;                             % heat absorbed from the exhaust [kWh]
W_p   = W_turb * sum(m_wf .* w_p) / w_t;                 % pump work [kWh]
W_net = W_turb - W_p;  Q_out = Q_in - W_net;             % net work, heat to the cooling water
k1 = time > 3600;                                        % after the first hour (start-up)
fprintf('\n=== ORC CYCLE ===\n');
fprintf('Heat absorbed       : %7.1f kWh  (exhaust -> R1233zd(E))\n', Q_in);
fprintf('Turbine work        : %7.1f kWh  (shaft %.1f = generator %.1f + losses %.1f)\n', W_turb, E_gen + E_aux, E_gen, E_aux);
fprintf('Pump work           : %7.2f kWh\n', W_p);
fprintf('Heat rejected       : %7.1f kWh  (condenser -> cooling water)\n', Q_out);
fprintf('ORC efficiency      : %7.1f %% (net work / heat absorbed)\n', 100*eta_orc);
fprintf('Evaporating pressure: %7.2f MPa  | condensing: %.2f MPa (mean after 1 h)\n', mean(p(k1,3))/1e6, mean(p(k1,1))/1e6);
fprintf('Turbine inlet       : %7.0f K    | pump inlet: %.0f K\n', mean(T(k1,3)), mean(T(k1,1)));
fprintf('Shaft speed         : %7.0f rad/s (min %.0f, max %.0f after 1 h)\n', mean(w_sh(k1)), min(w_sh(k1)), max(w_sh(k1)));
fprintf('Working fluid       : %7.3f kg/s mean | exhaust used: %.2f of %.2f kg/s available\n', mean(m_wf(k1)), mean(m_gs(k1)), mean(m_ex(k1)));
save('results.mat', 'time', 'P_gen', 'P_load', 'P_elec', 'I_elec', 'm_dot_H2', 'H2_cum', ...
     'm_wf', 'm_gs', 'm_ex', 'w_sh', 'h', 'T', 'p', 'E_gen', 'E_load', 'E_elec', 'm_H2', 'E_H2', ...
     'Q_in', 'W_turb', 'W_net', 'W_p', 'Q_out', 'E_aux', 'eta_orc', 'nWarn');

%% 7. Figures
days = time / 86400;
figure('Name', 'HRES results', 'NumberTitle', 'off', 'Position', [60 60 1100 800]);
subplot(3,1,1);
plot(days, P_gen/1e3, days, P_load/1e3, 'LineWidth', 1); grid on;
ylabel('Power (kW)'); legend('Generator', 'Load', 'Location', 'northwest');
title('Electrical power: generator and residential load');
subplot(3,1,2);
plot(days, P_elec/1e3, 'Color', [0.89 0.64 0.10], 'LineWidth', 1); grid on;
ylabel('Power (kW)'); title('Surplus power sent to the PEM electrolyzer');
subplot(3,1,3);
yyaxis left;  plot(days, m_dot_H2*3.6e6, 'LineWidth', 1); ylabel('H_2 rate (g/h)');
yyaxis right; plot(days, H2_cum, 'k', 'LineWidth', 2); ylabel('Cumulative H_2 (kg)');
grid on; xlabel('Day (from 1 April 2020)');
title(sprintf('Hydrogen production (total %.2f kg)', m_H2));

figure('Name', 'Energy fluxes', 'NumberTitle', 'off', 'Position', [120 120 1100 420]);
subplot(1,2,1);                                          % ORC: heat -> work
vo = [Q_in, Q_out, W_turb, E_aux, E_gen];
b = bar(vo, 'FaceColor', 'flat');
b.CData = [0.85 0.33 0.10; 0.62 0.62 0.62; 0.93 0.69 0.13; 0.62 0.62 0.62; 0.89 0.64 0.10];
set(gca, 'XTickLabel', {'Heat from exhaust', 'To cooling water', 'Turbine work', 'Shaft losses', 'Electricity'});
ylabel('Energy (kWh)'); grid on; title(sprintf('ORC (efficiency %.1f %%)', 100*eta_orc));
text(1:numel(vo), vo, compose('%.1f', vo), 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', 'FontWeight', 'bold');
ylim([0 1.15*max(vo)]);
subplot(1,2,2);                                          % electricity -> load and hydrogen
vals = [E_gen, E_load, E_elec, E_H2, E_elec - E_H2];
b = bar(vals, 'FaceColor', 'flat');
b.CData = [0.89 0.64 0.10; 0.24 0.43 0.71; 0.35 0.62 0.18; 0.16 0.65 0.79; 0.62 0.62 0.62];
set(gca, 'XTickLabel', {'Generated', 'To load', 'To electrolyzer', 'H_2 (LHV)', 'Stack losses'});
ylabel('Energy (kWh)'); grid on; title(sprintf('Electricity and hydrogen over %.2f days', n_days));
text(1:numel(vals), vals, compose('%.1f', vals), 'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'bottom', 'FontWeight', 'bold');
ylim([0 1.15*max(vals)]);

figure('Name', 'ORC cycle', 'NumberTitle', 'off', 'Position', [180 80 1100 800]);
subplot(3,1,1);
plot(days, p(:,3)/1e6, days, p(:,1)/1e6, 'LineWidth', 1); grid on; ylabel('Pressure (MPa)');
legend('Evaporator (turbine inlet)', 'Condenser (pump inlet)', 'Location', 'east');
title('ORC pressures');
subplot(3,1,2);
plot(days, T(:,3), days, T(:,4), days, T(:,1), 'LineWidth', 1); grid on; ylabel('Temperature (K)');
legend('Turbine inlet', 'Turbine outlet', 'Pump inlet', 'Location', 'east');
title('ORC temperatures');
subplot(3,1,3);
plot(days, m_wf, days, m_gs, days, m_ex, '--', 'LineWidth', 1); grid on; ylabel('Mass flow (kg/s)');
legend('Working fluid R1233zd(E)', 'Exhaust through the exchanger', 'Exhaust available', 'Location', 'east');
xlabel('Day (from 1 April 2020)');
title(sprintf('Flows (ORC efficiency %.1f %%)', 100*eta_orc));

% save the figures next to the repository figures
if exist(fullfile('..','figures'), 'dir')
    f = findobj('Type','figure'); names = containers.Map( ...
        {'HRES results','Energy fluxes','ORC cycle'}, {'13_results.png','14_energy_fluxes.png','15_orc_cycle.png'});
    for i = 1:numel(f)
        if isKey(names, f(i).Name), try, theme(f(i), 'light'); catch, end, exportgraphics(f(i), fullfile('..','figures', names(f(i).Name)), 'Resolution', 150); end
    end
end

%% ======================================================================
function y = getSignal(simOut, name, t)
% Returns a logged signal resampled on t (works with every To Workspace format).
    s = simOut.get(name);
    if isa(s, 'Simulink.SimulationData.Dataset'), s = s.getElement(1); if isprop(s,'Values'), s = s.Values; end, end
    if isa(s, 'timeseries'), ts = s.Time; d = s.Data;
    elseif isa(s, 'timetable'), ts = seconds(s.Properties.RowTimes); d = s{:,1};
    elseif isstruct(s), d = s.signals.values; if isfield(s,'time') && ~isempty(s.time), ts = s.time; else, ts = simOut.tout; end
    else, d = s; ts = simOut.tout; end
    d = double(squeeze(d)); d = d(:); ts = double(ts(:));
    n = min(numel(ts), numel(d)); [ts, iu] = unique(ts(1:n)); d = d(1:n); d = d(iu);
    y = interp1(ts, d, t, 'linear', 'extrap');
end

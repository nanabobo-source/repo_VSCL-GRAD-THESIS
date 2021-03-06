function [statevect,constraint] = ...
    dp_getenergymin(statevect,state,tbl,matr,vect,constraint,slope,param,ns)
% [statevect,constraint] = DP_MINENERGY(statevect,state,tbl,matr,vect,constraint,slope,param,ns)
%
% This function finds the subtotal minimum energy of the possible states
%
%=========================================================================
% ------------------------------- INPUTS ---------------------------------
%   statevect = structure which contains minimum of state calculated at
%               each new speed
% 
%   state = structure which contains the possible states at the current
%           iteration
% 
%   tbl   = structure which contains tables used to store the states
%           calculated during the DP algorithm
% 
%   matr  = structure which contains matrices used to store energy values
%           calculated during each iteration of the DP algorithm
% 
%   vect  = structure which constians vectors of all possible values of a 
%           given parameter
% 
%   constraint = structure which will contain vectors enforcing the given
%                constraints on the different states
% 
%   slope = structure which contains information
% 
%   param = structure which contains efficiencies, physical measurements,
%           limits of the EGV, and conversion factors
% 
%   ns  = structure which contains lengths of important vectors
% ------------------------------------------------------------------------
%
% ------------------------------ OUTPUTS ---------------------------------
%   statevect = structure which contains minimum of state calculated at
%               each new speed
%     ~.E = vector of possible energy states
%     ~.T = vector of possible in-wheel motor toqrues
%     ~.P = vector of possible power required
%     ~.t = vector of possible times taken between states
% 
%   constraint = structure which contains vectors enforcing the given
%                constraints on the different states
%     ~.T   = contraints due to torque limits
%     ~.SOC = contraints due to state of charge limits
% ------------------------------------------------------------------------
%=========================================================================

v2struct(param.conv);

%reset constraint variables
% constraint = resetstruct(constraint,'zero');

%limit the acceleration to the specified max
if abs(state.a) > param.lim.acc
    statevect = resetstruct(statevect,ns.nextspd,'nan');
    return
elseif state.v.next >= ns.speedLimit(1)*kmh2mps
    statevect = resetstruct(statevect,ns.nextspd,'nan');
    return
elseif state.v.next < ns.speedLimit(2)*kmh2mps
    statevect = resetstruct(statevect,ns.nextspd,'nan');
    return
end

statevect.t(ns.nextspd) = state.dt;
state.w.front = state.v.avg/param.R_eff;
state.w.rear  = state.v.avg/param.R_eff;

%based on type, apply correct normal force equations
switch slope.type
    case 'downhill'
        F.n1 = param.m*param.g/param.L*(1/2*cosd(slope.phi) +...
            param.b*sind(slope.phi)) - param.m*param.b/param.L*state.a;
        F.n2 = param.m*param.g/param.L*(1/2*cosd(slope.phi) -...
            param.b*sind(slope.phi)) + param.m*param.b/param.L*state.a;
        F.g  = -param.m*param.g*sind(slope.phi);
    case 'level'
        F.n1 = param.m*param.g/2 - param.m*param.b/param.L*state.a;
        F.n2 = param.m*param.g/2 + param.m*param.b/param.L*state.a;
        F.g  = 0;
    case 'uphill'
        F.n1 = param.m*param.g/param.L*(1/2*cosd(slope.theta) -...
            param.b*sind(slope.theta)) - param.m*param.b/param.L*state.a;
        F.n2 = param.m*param.g/param.L*(1/2*cosd(slope.theta) +...
            param.b*sind(slope.theta)) + param.m*param.b/param.L*state.a;
        F.g  = param.m*param.g*sind(slope.theta);
end

%forces on EGV from FBD
% F.g = param.m*param.g*sind(slope.total(ns.k)); %gravity component along slope
F.w = param.Ca*state.v.avg^2; %aerodynamic resistance (drag)
F.a = param.m*state.a;        %acceleration resistance
%calculate required power based on forces
state.P.req   = state.v.avg/2*(F.g + F.w + F.a);
state.P.front = state.w.front.*state.T.front; %P1<0 generator, P1>=0 motor
state.P.rear  = state.P.req - state.P.front;  %satisfy speed equality constraints
state.T.rear  = state.P.rear./state.w.rear;

%---------------------------------%
%------- apply constraints -------%
%---------------------------------%
%1: torque boundary constraints
constraint.T.range = find(state.T.rear>=param.lim.T2.min & ...
  state.T.rear<=param.lim.T2.max);
  state.T.front = state.T.front(constraint.T.range);
  state.T.rear  = state.T.rear(constraint.T.range);
%2: torque terrain (normal force) constraints
constraint.T.rearmax = find(state.T.rear <= F.n2*param.mu*param.R_eff);
  state.T.front = state.T.front(constraint.T.rearmax);
  state.T.rear  = state.T.rear(constraint.T.rearmax);
constraint.T.frontmax = find(state.T.front <= F.n1*param.mu*param.R_eff);
  state.T.front = state.T.front(constraint.T.frontmax);
  state.T.rear  = state.T.rear(constraint.T.frontmax);
%---------------------------------%
%------- apply constraints -------%
%---------------------------------%

%--POPULATE VECTORS WITH POSSIBLE CONTROL VALUES--
%find lengths of constrained torque vectors
a(1) = length(state.T.front);
a(2) = length(state.T.rear);
if a(1)~=a(2)
    %if the torque vectors are not the same size, something went wrong
    error('T1 and T2 have different dimensions')
elseif a(1)==0
    %if no torques fall within specified range, set everything to NANs
    statevect = resetstruct(statevect,ns.nextspd,'nan');
    return
end
%get motor efficiencies at specified speed and torque values
for i=1:a(1)
    motorEff.front(i) = getMotorEff(state.v.avg,state.T.front(i),param.R_eff);
    motorEff.rear(i)  = getMotorEff(state.v.avg,state.T.rear(i),param.R_eff);
end
%evaluate efficiency based on the possible torque values
eta.front = zeros(a(1),1);
eta.rear  = zeros(a(2),1);
for i=1:a(1)
    if state.T.front(i)<0
        eta.front(i) = param.eff.brake.front*motorEff.front(i);
        if state.T.rear(i)<0
            state.P.type = 'regenBoth';
            eta.rear(i)  = param.eff.brake.rear*motorEff.rear(i);
        else
            state.P.type = 'regenFront';
            eta.rear(i)  = 1/(param.eff.drive.rear*motorEff.rear(i));
        end
    else
        eta.front(i) = 1/(param.eff.drive.front*motorEff.front(i));
        if state.T.rear(i)<0
            state.P.type = 'regenRear';
            eta.rear(i)  = param.eff.brake.rear*motorEff.rear(i);
        else
            state.P.type = 'regenNone';
            eta.rear(i)  = 1/(param.eff.drive.rear*motorEff.rear(i));
        end
    end
end
%calculate power
Pg1 = state.w.front.*state.T.front;
Pg2 = state.w.rear.*state.T.rear;
state.P.total = Pg1.*eta.front + Pg2.*eta.rear;

%--POPULATE VECTORS EITH POSSIBLE STATE VALUES--
%calculate change in state of charge
SOC.delta = state.P.total*state.dt/(param.E_max*param.V_bat*hr2sec);
%---------------------------------%
%------- apply constraints -------%
%---------------------------------%
if ns.k==ns.N
    constraint.SOC = find(abs(SOC.delta) <= param.lim.SOE.max-param.lim.SOE.min);
else
    %3: state of charge boundary constraint
    SOC.currmin = min(matr.SOE(ns.currspd,:,ns.k));
    SOC.currmax = max(matr.SOE(ns.currspd,:,ns.k));
    constraint.SOC = find(...
        SOC.currmin+SOC.delta <= param.lim.SOE.max |...
        SOC.currmax+SOC.delta >= param.lim.SOE.min);
end
%apply constraints to power and torque vectors
state.P.total = state.P.total(constraint.SOC);
state.T.front = state.T.front(constraint.SOC);
state.T.rear  = state.T.rear(constraint.SOC);
%find min value and index
[state.P.min,ind_pmin] = min(state.P.total);
%insert the calculated min into the slot for the next speed
if isempty(state.T.front(ind_pmin)) || isempty(state.T.rear(ind_pmin))
    statevect = resetstruct(statevect,ns.nextspd,'nan');
else
    statevect.P(ns.nextspd) = state.P.min;
    statevect.T.front(ns.nextspd) = state.T.front(ind_pmin);
    statevect.T.rear(ns.nextspd) = state.T.rear(ind_pmin);
end
%---------------------------------%
%------- apply constraints -------%
%---------------------------------%

%--CALCULATE MIN ENERGY CONSUMPTION OF ALL POSSIBLE STATES FROM THE NEXT
%POINT TO THE DESTINATION--
statevect.E.sub(ns.nextspd) = statevect.P(ns.nextspd)*statevect.t(ns.nextspd);
if ns.k==ns.N
    statevect.E.subtot(ns.nextspd) = statevect.E.sub(ns.nextspd) + param.E_final;
else
    ind_nextv = find(abs(vect.v - state.v.next/kmh2mps) <= 0.001);
    if isempty(ind_nextv)
        statevect.E.subtot(ns.nextspd) = NaN;
    else
        statevect.E.subtot(ns.nextspd) = statevect.E.sub(ns.nextspd)+...
            tbl.E(ind_nextv,ns.k+1);
    end
end

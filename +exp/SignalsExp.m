classdef SignalsExp < handle
  %EXP.SIGNALSEXP Base class for stimuli-delivering experiments
  %   The class defines a framework for event- and state-based experiments.
  %   Visual and auditory stimuli can be controlled by experiment phases.
  %   Phases changes are managed by an event-handling system.
  %
  % Part of Rigbox

  % 2012-11 CB created
  
  properties
    %An array of event handlers. Each should specify the name of the
    %event that activates it, callback functions to be executed when
    %activated and an optional delay between the event and activation.
    %They should be objects of class EventHandler.
    EventHandlers = exp.EventHandler.empty
    
    %Timekeeper used by the experiment. Clocks return the current time. See
    %the Clock class definition for more information.
    Clock = hw.ptb.Clock
    
    %Key for terminating an experiment whilst running. Shoud be a
    %Psychtoolbox keyscan code (see PTB KbName function).
    QuitKey = KbName('q')
    
    PauseKey = KbName('esc') %Key for pausing an experiment
    
    %String description of the type of experiment, to be saved into the
    %block data field 'expType'.
    Type = ''
    
    %Reference for the rig that this experiment is being run on, to be
    %saved into the block data field 'rigName'.
    RigName
    
    %Communcator object for sending signals updates to mc.  Set by
    %expServer
    Communicator = io.DummyCommunicator
    
    %Delay (secs) before starting main experiment phase after experiment
    %init phase has completed
    PreDelay = 0 
    
    %Delay (secs) before beginning experiment cleanup phase after
    %main experiment phase has completed (assuming an immediate abort
    %wasn't requested).
    PostDelay = 0
    
    %Flag indicating whether the experiment is paused
    IsPaused = false 
    
    %Holds the wheel object, 'mouseInput' from the rig object.  See also
    %USERIG, HW.DAQROTARYENCODER
    Wheel
    
    %Holds the object for interating with the lick detector.  See also
    %HW.DAQEDGECOUNTER
    LickDetector
    
    %Holds the object for interating with the DAQ outputs (reward valve,
    %etc.)  See also HW.DAQCONTROLLER
    DaqController
    
    %Get the handle to the PTB window opened by expServer
    StimWindowPtr
    
    TextureById
    
    LayersByStim
    
    %Occulus viewing model
    Occ 
    
    Time
    
    Inputs
    
    Outputs
    
    Events
    
    Visual
    
    Audio % = aud.AudioRegistry
    
    %Holds the parameters structure for this experiment
    Params
    
    ParamsLog
    
    %The bounds for the photodiode square
    SyncBounds
    
    %Sync colour cycle (usually [0, 255]) - cycles through these each
    %time the screen flips.
    SyncColourCycle
    
    %Index into SyncColourCycle for next sync colour
    NextSyncIdx 
    
    %Holds the session for the DAQ photodiode echo, used if
    %rig.stimWindow.DaqSyncEchoPort is defined.  See also USERIG
    DaqSyncEcho

    % Alyx instance from client.  See also SAVEDATA
    AlyxInstance = []
  end
  
  properties (SetAccess = protected)     
    %Number of stimulus window flips
    StimWindowUpdateCount = 0
    
    %Data from the currently running experiment, if any.
    Data = struct
    
    %Data binary file ID and pars file ID for intermittent saving
    DataFID
    
    %Currently active phases of the experiment. Cell array of their names
    %(i.e. strings)
    ActivePhases = {}
    
    Listeners
    
    Net
    
    SignalUpdates = struct('name', cell(500,1), 'value', cell(500,1), 'timestamp', cell(500,1))
    NumSignalUpdates = 0
  end
  
  properties (Access = protected)
    %Set triggers awaiting activation: a list of Triggered objects, which
    %are awaiting activation pending completion of their delay period.
    Pending
    
    %Flag indicating whether to continue in experiment loop
    IsLooping = false 
    
    AsyncFlipping = false
    
    StimWindowInvalid = false
  end
  
  methods
    function obj = SignalsExp(paramStruct, rig)
      clock = rig.clock;
      clockFun = @clock.now;
      obj.TextureById = containers.Map('KeyType', 'char', 'ValueType', 'uint32');
      obj.LayersByStim = containers.Map;
      obj.Inputs = sig.Registry(clockFun);
      obj.Outputs = sig.Registry(clockFun);
      obj.Visual = StructRef;
      nAudChannels = getOr(paramStruct, 'numAudChannels', rig.audioDevice.NrOutputChannels);
      audSampleRate = getOr(paramStruct, 'audSampleRate', rig.audioDevice.DefaultSampleRate); % Hz
      audDevIdx = getOr(paramStruct, 'audDevIdx', rig.audioDevice.DeviceIndex); % -1 means use system default
      obj.Audio = audstream.Registry(audSampleRate, nAudChannels, audDevIdx);
      obj.Events = sig.Registry(clockFun);
      %% configure signals
      net = sig.Net;
      obj.Net = net;
      obj.Time = net.origin('t');
      obj.Events.expStart = net.origin('expStart');
      obj.Events.newTrial = net.origin('newTrial');
      obj.Events.expStop = net.origin('expStop');
      obj.Inputs.wheel = net.origin('wheel');
      obj.Inputs.keyboard = net.origin('keyboard');
      % get global parameters & conditional parameters structs
      [~, globalStruct, allCondStruct] = toConditionServer(...
        exp.Parameters(paramStruct));
      % start the first trial after expStart
      advanceTrial = net.origin('advanceTrial');
      % configure parameters signal
      globalPars = net.origin('globalPars');
      allCondPars = net.origin('condPars');
      [obj.Params, hasNext, obj.Events.repeatNum] = exp.trialConditions(...
        globalPars, allCondPars, advanceTrial);
      
      obj.Events.trialNum = obj.Events.newTrial.scan(@plus, 0); % track trial number
      
      lastTrialOver = then(~hasNext, true);
      
%       obj.Events.expStop = then(~hasNext, true);
      % run experiment definition
      if ischar(paramStruct.defFunction)
        expDefFun = fileFunction(paramStruct.defFunction);
        obj.Data.expDef = paramStruct.defFunction;
      else
        expDefFun = paramStruct.defFunction;
        obj.Data.expDef = func2str(expDefFun);
      end
      fprintf('takes %i args\n', nargout(expDefFun));
      expDefFun(obj.Time, obj.Events, obj.Params, obj.Visual, obj.Inputs,...
        obj.Outputs, obj.Audio);
      % listeners
      obj.Listeners = [
        obj.Events.expStart.map(true).into(advanceTrial) %expStart signals advance
        obj.Events.endTrial.into(advanceTrial) %endTrial signals advance
        advanceTrial.map(true).keepWhen(hasNext).into(obj.Events.newTrial) %newTrial if more
        lastTrialOver.onValue(@(~)quit(obj));];
%         obj.Events.trialNum.onValue(fun.partial(@fprintf, 'trial %i started\n'))];
      % initialise the parameter signals
      globalPars.post(rmfield(globalStruct, 'defFunction'));
      allCondPars.post(allCondStruct);
      %% data struct
      
%       obj.Params = obj.Params.map(@(v)v, [], @(n,s)sig.Logger([n '[L]'],s));
      %initialise stim window frame times array, large enough for ~2 hours
      obj.Data.stimWindowUpdateTimes = zeros(60*60*60*2, 1);
      obj.Data.stimWindowRenderTimes = zeros(60*60*60*2, 1);
%       obj.Data.stimWindowUpdateLags = zeros(60*60*60*2, 1);
      obj.ParamsLog = obj.Params.log();
      obj.useRig(rig);
    end
    
    function useRig(obj, rig)
      % USERIG(OBJ, RIG) Initialize all hardware for experiment
      %   Takes the rig hardware structure and loads the relevant
      %   parameters into the class properties, namely the DAQ output
      %   channels and the stimWindow properties.
      %
      % See Also HW.PTB.WINDOW, DAQCONTROLLER

      obj.Clock = rig.clock;
      obj.Data.rigName = rig.name;
      % Sync bounds parameter for photodiode square
      obj.SyncBounds = rig.stimWindow.SyncBounds;
      % Sync colour cycle (usually [0, 255]) - cycles through these each
      % time the screen flips.
      obj.SyncColourCycle = rig.stimWindow.SyncColourCycle;
      % If the DaqSyncEchoPort is defined, each time the screen flips, the
      % DAQ will output an alternating high or low.  This signals will
      % follow the photodiode signal.
      if ~isempty(rig.stimWindow.DaqSyncEchoPort)
        % Create the DAQ session for the sync echo
        obj.DaqSyncEcho = daq.createSession(rig.stimWindow.DaqVendor);
        % Add the digital channel using parameters defined in
        % rig.stimWindow
        obj.DaqSession.addDigitalChannel(rig.stimWindow.DaqDev,...
          rig.stimWindow.DaqSyncEchoPort, 'OutputOnly');
        % Output an initial 0V signal
        obj.DaqSession.outputSingleScan(false);
      end
      % Initialize the sync square colour to be index 1
      obj.NextSyncIdx = 1;
      % Get the handle to the PTB window opened by expServer
      obj.StimWindowPtr = rig.stimWindow.PtbHandle;
      % Generate the viewing model based on the screen information from the
      % rig struct, if availiable
      obj.Occ = vis.init(obj.StimWindowPtr);
      if isfield(rig, 'screens')
        obj.Occ.screens = rig.screens;
      else
        warning('squeak:hw', 'No screen configuration specified. Visual locations will be wrong.');
      end
      % Load the DAQ outputs
      obj.DaqController = rig.daqController;
      % Load the wheel
      obj.Wheel = rig.mouseInput;
      if isfield(rig, 'lickDetector')
        obj.LickDetector = rig.lickDetector;
      end
      if ~isempty(obj.DaqController.SignalGenerators)
          outputNames = fieldnames(obj.Outputs); % Get list of all outputs specified in expDef function
          for m = 1:length(outputNames)
              id = find(strcmp(outputNames{m},...
                  obj.DaqController.ChannelNames)); % Find matching channel from rig hardware file
              if id % if the output is present, create callback 
                  obj.Listeners = [obj.Listeners
                    obj.Outputs.(outputNames{m}).onValue(@(v)obj.DaqController.command([zeros(size(v,1),id-1) v])) % pad value with zeros in order to output to correct channel
                    obj.Outputs.(outputNames{m}).onValue(@(v)fprintf('delivering output of %.2f\n',v))
                    ];   
              elseif strcmp(outputNames{m}, 'reward') % special case; rewardValve is always first signals generator in list 
                  obj.Listeners = [obj.Listeners
                    obj.Outputs.reward.onValue(@(v)obj.DaqController.command(v))
                    obj.Outputs.reward.onValue(@(v)fprintf('delivering reward of %.2f\n', v))
                    ];   
              end
          end
      end
    end

    function abortPendingHandlers(obj, handler)
      if nargin < 2
        % Sets all pending triggers inactive
        [obj.Pending(:).isActive] = deal(false);
      else
        % Sets pending triggers for specified handler inactive
        abortList = ([obj.Pending.handler] == handler);
        [obj.Pending(abortList).isActive] = deal(false);
      end
    end
    
    function startPhase(obj, name, time)
      % Starts a phase
      %
      % startPhase(NAME, TIME) causes a phase to start. The phase is added
      % to the list of active phases. The change is also signalled to any 
      % interested triggers as having occured at TIME.
      % 
      % Note: The time specified is signalled to the triggers, which is
      % important for maintaining rigid timing offsets even if there are
      % delays in calling this function. e.g. if a trigger is set to go off
      % one second after a phase starts, the trigger will become due one
      % second after the time specified, *not* one second from calling this
      % function.

      % make sure the phase isn't already active
      if ~any(strcmpi(obj.ActivePhases, name))      
        % add the phase from list
        obj.ActivePhases = [obj.ActivePhases; name];

        % action any triggers contingent on this phase change
        fireEvent(obj, exp.EventInfo([name 'Started'], time, obj));
      end
    end

    function endPhase(obj, name, time)
      % Ends a phase
      %
      % endPhase(NAME, TIME) causes a phase to end. The phase is removed 
      % from the list of active phases. The event is also signalled to any
      % interested triggers as having occured at TIME.
      % 
      % Note: The time specified is signalled to the triggers, which is
      % important for maintaining rigid timing offsets even if there are
      % delays in calling this function. e.g. if a trigger is set to go off
      % one second after a phase starts, the trigger will become due one
      % second after the time specified, *not* one second from calling this
      % function.
      
      % make sure the phase is active
      if any(strcmpi(obj.ActivePhases, name))      
        % remove the phase from list
        obj.ActivePhases(strcmpi(obj.ActivePhases, name)) = [];

        % action any triggers contingent on this phase change
        fireEvent(obj, exp.EventInfo([name 'Ended'], time, obj));
      end
    end   
    
    function addEventHandler(obj, handler, varargin)
      % Adds one or more event handlers
      %
      % addEventHandler(HANLDER) adds one or more handlers specified by the 
      % HANLDER parameter (either a single object of class EventHandler, or
      % an array of them), to this experiment's list of handlers.
      if iscell(handler)
        handler = cell2mat(handler);
      end
      obj.EventHandlers = [obj.EventHandlers; handler(:)];
      if ~isempty(varargin)
        % deal with extra handle arguments recursively
        addEventHandler(obj, varargin{:});
      end
    end
    
    function data = run(obj, ref)
      % Runs the experiment
      %
      % run(REF) will start the experiment running, first initialising
      % everything, then running the experiment loop until the experiment
      % is complete. REF is a reference to be saved with the block data
      % under the 'expRef' field, and will be used to ascertain the
      % location to save the data into. If REF is an empty, i.e. [], the
      % data won't be saved.
      
      if ~isempty(ref)
        %ensure experiment ref exists
        assert(dat.expExists(ref), 'Experiment ref ''%s'' does not exist', ref);
      end
      
      %do initialisation
      init(obj);
      
      obj.Data.expRef = ref; %record the experiment reference
      
      %Trigger the 'experimentInit' event so any handlers will be called
      initInfo = exp.EventInfo('experimentInit', obj.Clock.now, obj);
      fireEvent(obj, initInfo);
      
      %set pending handler to begin the experiment 'PreDelay' secs from now
      start = exp.EventHandler('experimentInit', exp.StartPhase('experiment'));
      start.addCallback(@(varargin) obj.Events.expStart.post(ref));
      obj.Pending = dueHandlerInfo(obj, start, initInfo, obj.Clock.now + obj.PreDelay);
      
      %refresh the stimulus window
      Screen('Flip', obj.StimWindowPtr);
      
      try
        % start the experiment loop
        mainLoop(obj);
        
        %post comms notification with event name and time
        if isempty(obj.AlyxInstance)
          post(obj, 'AlyxRequest', obj.Data.expRef); %request token from client
          pause(0.2) 
        end
        
        %Trigger the 'experimentCleanup' event so any handlers will be called
        cleanupInfo = exp.EventInfo('experimentCleanup', obj.Clock.now, obj);
        fireEvent(obj, cleanupInfo);
        
        %do our cleanup
        cleanup(obj);
        
        %return the data structure that has been built up
        data = obj.Data;
                
        if ~isempty(ref)
          saveData(obj); %save the data
        end
      catch ex
        %mark that an exception occured in the block data, then save
        obj.Data.endStatus = 'exception';
        obj.Data.exceptionMessage = ex.message;
        if ~isempty(ref)
          saveData(obj); %save the data
        end
        ensureWindowReady(obj); % complete any outstanding refresh
        %rethrow the exception
        rethrow(ex)
      end
    end
    
    function bool = inPhase(obj, name)
      % Reports whether currently in specified phase
      %
      % inPhase(NAME) checks whether the experiment is currently in the
      % phase called NAME.
      bool = any(strcmpi(obj.ActivePhases, name));
    end
    
    function log(obj, field, value)
      % Logs the value in the experiment data
      if isfield(obj.Data, field)
        obj.Data.(field) = [obj.Data.(field) value];
      else
        obj.Data.(field) = value;
      end
    end
    
    function quit(obj, immediately)
      obj.Events.expStop.post(true);
      %stop delay timers. todo: need to use a less global tag
      tmrs = timerfind('Tag', 'sig.delay');
      if ~isempty(tmrs)
        stop(tmrs);
        delete(tmrs);
      end
      
      % set any pending handlers inactive
      abortPendingHandlers(obj);
      
      % clear all phases except 'experiment' "dirtily", i.e. without
      % setting off any triggers for those phases.
      % *** IN FUTURE MAY CHANGE SO THAT WE DO END TRIAL CLEANLY ***
      if nargin < 2
        immediately = false;
      end
      
      if inPhase(obj, 'experiment')
        obj.ActivePhases = {'experiment'}; % clear active phases except experiment
        % end the experiment phase "cleanly", i.e. with triggers
        endPhase(obj, 'experiment', obj.Clock.now);
      else
        obj.ActivePhases = {}; %clear active phases
      end
      
      if immediately
        %flag as 'aborted' meaning terminated early, and as quickly as possible
        obj.Data.endStatus = 'aborted';
      else
        %flag as 'quit', meaning quit before all trials were naturally complete,
        %but still shut down with usual cleanup delays etc
        obj.Data.endStatus = 'quit';
      end

      if immediately || obj.PostDelay == 0
        obj.IsLooping = false; %unset looping flag now
      else
        %add a pending handler to unset looping flag
        %NB, since we create a pending item directly, the EventHandler delay
        %and triggering event name are only set for clarity and wont be
        %used
        endExp = exp.EventHandler('experimentEnded'); %event name just for clarity
        endExp.Delay = obj.PostDelay; %delay just for clarity
        endExp.addCallback(@stopLooping);
        pending = dueHandlerInfo(obj, endExp, [], obj.Clock.now + obj.PostDelay);
        obj.Pending = [obj.Pending, pending];
      end
      
      function stopLooping(varargin)
        obj.IsLooping = false;
      end
    end
    
    function ensureWindowReady(obj)
      % complete any outstanding asynchronous flip
      if obj.AsyncFlipping
        % wait for flip to complete, and record the time
        time = Screen('AsyncFlipEnd', obj.StimWindowPtr);
        obj.AsyncFlipping = false;
        time = fromPtb(obj.Clock, time); %convert ptb/sys time to our clock's time
%         assert(obj.Data.stimWindowUpdateTimes(obj.StimWindowUpdateCount) == 0);
        obj.Data.stimWindowUpdateTimes(obj.StimWindowUpdateCount) = time;
%         lag = time - obj.Data.stimWindowRenderTimes(obj.StimWindowUpdateCount);
%         obj.Data.stimWindowUpdateLags(obj.StimWindowUpdateCount) = lag;
      end
    end
    
    function queueSignalUpdate(obj, name, value)
      timestamp = clock;
      nupdates = obj.NumSignalUpdates;
      if nupdates == length(obj.SignalUpdates)
        %grow message queue by doubling in size
        obj.SignalUpdates(2*end+1).value = [];
      end
      idx = nupdates + 1;
      obj.SignalUpdates(idx).name = name;
      obj.SignalUpdates(idx).value = value;
      obj.SignalUpdates(idx).timestamp = timestamp;
      obj.NumSignalUpdates = idx;
    end
      
    function post(obj, id, msg)
      send(obj.Communicator, id, msg);
    end
    
    function sendSignalUpdates(obj)
      try
        if obj.NumSignalUpdates > 0
          post(obj, 'signals', obj.SignalUpdates(1:obj.NumSignalUpdates));
        end
      catch ex
        warning(getReport(ex));
      end
      obj.NumSignalUpdates = 0;
    end
    
    function loadVisual(obj, name)
      %% configure signals
      layersSig = obj.Visual.(name).Node.CurrValue.layers;
      obj.Listeners = [obj.Listeners
        layersSig.onValue(fun.partial(@obj.newLayerValues, name))];
      newLayerValues(obj, name, layersSig.Node.CurrValue);

%       %% load textures
%       layerData = obj.LayersByStim(name);
%       Screen('BeginOpenGL', win);
%       try
%         for ii = 1:numel(layerData)
%           id = layerData(ii).textureId;
%           if ~obj.TextureById.isKey(id)
%             obj.TextureById(id) = ...
%               vis.loadLayerTextures(layerData(ii));
%           end
%         end
%       catch glEx
%         Screen('EndOpenGL', win);
%         rethrow(glEx);
%       end
%       Screen('EndOpenGL', win);
    end
    
    function newLayerValues(obj, name, val)
%       fprintf('new layer value for %s\n', name);
%       show = [val.show]
      if isKey(obj.LayersByStim, name)
        prev = obj.LayersByStim(name);
        prevshow = any([prev.show]);
      else
        prevshow = false;
      end
      obj.LayersByStim(name) = val;

      if any([val.show]) || prevshow
        obj.StimWindowInvalid = true;
      end
      
    end

    function delete(obj)
      disp('delete exp.SqueakExp');
      obj.Net.delete();
    end
  end
  
  methods (Access = protected)
    function init(obj)
      % Performs initialisation before running
      %
      % init() is called when the experiment is run before the experiment
      % loop begins. Subclasses can override to perform their own
      % initialisation, but must chain a call to this.
            
      % create and initialise a key press queue for responding to input
      KbQueueCreate();
      KbQueueStart();
      
      % MATLAB time stamp for starting the experiment
      obj.Data.startDateTime = now;
      obj.Data.startDateTimeStr = datestr(obj.Data.startDateTime);
      
      %init end status to nothing
      obj.Data.endStatus = [];
      
      % load each visual stimulus
      cellfun(@obj.loadVisual, fieldnames(obj.Visual));
      % each event signal should send signal updates
      queuefun = @(n,s)s.onValue(fun.partial(@queueSignalUpdate, obj, n));
      evtlist = mapToCell(@(n,v)queuefun(['events.' n],v),...
          fieldnames(obj.Events), struct2cell(obj.Events));
      outlist = mapToCell(@(n,v)queuefun(['outputs.' n],v),...
          fieldnames(obj.Outputs), struct2cell(obj.Outputs));
      obj.Listeners = vertcat(obj.Listeners, evtlist(:), outlist(:));
      
      % open binary file for saving block data.  This can later be retrieved
      % in case of a crash
      fprintf(1, 'opening binary file for writing\n');
      localPath = dat.expFilePath(obj.Data.expRef, 'block', 'local'); % get the local exp data path
      obj.DataFID = fopen([localPath(1:end-4) '.dat'], 'w'); % open a binary data file
      % save params now so if things crash later you at least have this record of the data type and size so you can load the dat
      obj.DataFID(2) = fopen([localPath(1:end-4) '.par'], 'w'); % open a parameter file
      
    end
    
    function cleanup(obj)
      % Performs cleanup after experiment completes
      %
      % cleanup() is called when the experiment is run after the experiment
      % loop completes. Subclasses can override to perform their own 
      % cleanup, but must chain a call to this.
      
      stopdatetime = now;
      %clear the stimulus window
      Screen('Flip', obj.StimWindowPtr);
      
      % collate the logs
      %events
      obj.Data.events = logs(obj.Events, obj.Clock.ReferenceTime);
      %params
      parsLog = obj.ParamsLog.Node.CurrValue;
      obj.Data.paramsValues = [parsLog.value];
      obj.Data.paramsTimes = [parsLog.time];
      %inputs
      obj.Data.inputs = logs(obj.Inputs, obj.Clock.ReferenceTime);
      %outputs
      obj.Data.outputs = logs(obj.Outputs, obj.Clock.ReferenceTime);
      %audio
%       obj.Data.audio = logs(audio, clockZeroTime);
      
      % MATLAB time stamp for ending the experiment
      obj.Data.endDateTime = stopdatetime;
      obj.Data.endDateTimeStr = datestr(obj.Data.endDateTime);
      
      % some useful data
      obj.Data.duration = etime(...
        datevec(obj.Data.endDateTime), datevec(obj.Data.startDateTime));
      
      %clip the stim window update times array
      obj.Data.stimWindowUpdateTimes((obj.StimWindowUpdateCount + 1):end) = [];
%       obj.Data.stimWindowUpdateLags((obj.StimWindowUpdateCount + 1):end) = [];
      obj.Data.stimWindowRenderTimes((obj.StimWindowUpdateCount + 1):end) = [];
      
      % release resources
      obj.Listeners = [];
      deleteGlTextures(obj);
      KbQueueStop();
      KbQueueRelease();
      
      % delete cached experiment definition function from memory
      [~, exp_func] = fileparts(obj.Data.expDef);
      clear(exp_func)
    end
    
    function deleteGlTextures(obj)
      tex = cell2mat(obj.TextureById.values);
      win = obj.StimWindowPtr;
      fprintf('Deleting %i textures\n', numel(tex));
      Screen('AsyncFlipEnd', win);
      Screen('BeginOpenGL', win);
      glDeleteTextures(numel(tex), tex);
      obj.TextureById.remove(obj.TextureById.keys);
      Screen('EndOpenGL', win);
    end
    
    function mainLoop(obj)
      % Executes the main experiment loop
      %
      % mainLoop() enters a loop that updates the stimulus window, checks
      % for and deals with inputs, updates state and activates triggers.
      % Will run until the experiment completes (phase 'experiment' ends).
      
      %set looping flag
      obj.IsLooping = true;
      % begin the loop
      while obj.IsLooping
        %% create a list of handlers that have become due
        dueIdx = find([obj.Pending.dueTime] <= now(obj.Clock));
        ndue = length(dueIdx);
        
        %% check for and process any input
        checkInput(obj);

        %% execute pending event handlers that have become due
        for i = 1:ndue
          due = obj.Pending(dueIdx(i));
          if due.isActive % check handler is still active
            activateEventHandler(obj, due.handler, due.eventInfo, due.dueTime);
            obj.Pending(dueIdx(i)).isActive = false; % set as inactive in pending
          end
        end

        % now remove executed (or otherwise inactived) ones from pending
        inactiveIdx = ~[obj.Pending.isActive];
        obj.Pending(inactiveIdx) = [];
        
        %% signalling
%         tic
        wx = readAbsolutePosition(obj.Wheel);
        post(obj.Inputs.wheel, wx);
        post(obj.Time, now(obj.Clock));
        runSchedule(obj.Net);
        
%         runSchedule(obj.Net);
%         nChars = overfprintf(nChars, 'post took %.1fms\n', 1000*toc);
        
        %% redraw the stimulus window if it has been invalidated
        if obj.StimWindowInvalid
          ensureWindowReady(obj); % complete any outstanding refresh
          % draw the visual frame
%           tic
          drawFrame(obj);
%           toc;
          if ~isempty(obj.SyncBounds) % render sync rectangle
            % render sync region with next colour in cycle
            col = obj.SyncColourCycle(obj.NextSyncIdx,:);
            % render rectangle in the sync region bounds in the required colour
            Screen('FillRect', obj.StimWindowPtr, col, obj.SyncBounds);
            % cyclically increment the next sync idx
            obj.NextSyncIdx = mod(obj.NextSyncIdx, size(obj.SyncColourCycle, 1)) + 1;
            if ~isempty(obj.DaqSyncEcho)
              % update sync echo
              outputSingleScan(obj.DaqSyncEcho, mean(col) > 0);
            end
          end
          renderTime = now(obj.Clock);
          % start the 'flip' of the frame onto the screen
          Screen('AsyncFlipBegin', obj.StimWindowPtr);
          obj.AsyncFlipping = true;
          obj.StimWindowUpdateCount = obj.StimWindowUpdateCount + 1;
          obj.Data.stimWindowRenderTimes(obj.StimWindowUpdateCount) = renderTime;
          obj.StimWindowInvalid = false;
        end
        sendSignalUpdates(obj);
        drawnow; % allow other callbacks to execute
      end
      ensureWindowReady(obj); % complete any outstanding refresh
    end
    
    function checkInput(obj)
      % Checks for and handles inputs during experiment
      %
      % checkInput() is called during the experiment loop to check for and
      % handle any inputs. This function specifically checks for any 
      % keyboard input that occurred since the last check, and passes that
      % information on to handleKeyboardInput. Subclasses should override
      % this function to check for any non-keyboard inputs of interest, but
      % must chain a call to this function.
      [pressed, keysPressed] = KbQueueCheck();
      if pressed
        if any(keysPressed(obj.QuitKey))
          % handle the quit key being pressed
          if strcmp(obj.Data.endStatus, 'quit')
            %quitting already in progress - a second time means fast abort
            fprintf('Abort fast (quit key pressed during quitting)\n');
            obj.quit(true);
          else
            fprintf('Quit key pressed\n');
            obj.quit(false);
          end
        elseif any(keysPressed(obj.PauseKey))
          fprintf('Pause key pressed\n');
          if obj.IsPaused
            resume(obj);
          else
            pause(obj);
          end
        else
%           key = keysPressed(find(keysPressed~=obj.QuitKey&...
%               keysPressed~=obj.PauseKey,1,'first'));
          key = KbName(keysPressed);
          if ~isempty(key)
            post(obj.Inputs.keyboard, key(1));
          end
        end
      end
    end
    
    function fireEvent(obj, eventInfo, logEvent)
      %fireEvent Called when an event occurs to log and handle them
      %   fireEvent(EVENTINFO) logs the time of the event, and checks the list 
      %   of experiment event handlers for any that are listening to the event 
      %   detailed in EVENTINFO. Those that are will be activated after their 
      %   desired delay period. EVENTINFO must be an object of class EventInfo.
      
      event = eventInfo.Event;
      
      %post comms notification with event name and time
      tnow = now(obj.Clock);
      msg = {'update', obj.Data.expRef, 'event', event, tnow};
      post(obj, 'status', msg);
      
      if nargin < 3
        % log events by default
        logEvent = true;
      end
      
      if logEvent
        % Save the actual time the event completed. For events that occur
        % during a trial, timestamps are saved within the trial data, otherwise
        % we just save in experiment-wide data.
        log(obj, [event 'Time'], tnow);
      end
      
      % create a list of handlers for this event
      if isempty(obj.EventHandlers)
        % handle special case bug in matlab
        % if EventHandlers is empty, the alternate case below will fail so
        % we handle it here
        handleEventNames = {};
      else
        handleEventNames = {obj.EventHandlers.Event};
      end
      
      evexp = ['(^|\|)' event '($|\|)'];
      match = ~strcmp(regexp(handleEventNames, evexp, 'match', 'once'), '');
      handlers = obj.EventHandlers(match);
      nhandlers = length(handlers);
      for i = 1:nhandlers
        if islogical(handlers(i).Delay) && handlers(i).Delay == false
          % delay is false, so activate immediately
          due = eventInfo.Time;
          immediate = true;
        else
          % delayed handler
          due = eventInfo.Time + handlers(i).Delay.secs;
          immediate = false;
        end

        % if the handler has no delay, then activate it now,
        % otherwise add it to our pending list
        if immediate
          activateEventHandler(obj, handlers(i), eventInfo, due);
        else
          pending = dueHandlerInfo(obj, handlers(i), eventInfo, due);
          obj.Pending = [obj.Pending, pending]; % append to pending handlers
        end
      end
    end
    
    function s = dueHandlerInfo(~, handler, eventInfo, dueTime)
      s = struct('handler', handler,...
        'eventInfo', eventInfo,...
        'dueTime', dueTime,...
        'isActive', true); % handlers starts active
    end

    function drawFrame(obj)
      % Called to draw current stimulus window frame
      %
      % drawFrame(obj) does nothing in this class but can be overrriden
      % in a subclass to draw the stimulus frame when it is invalidated
      win = obj.StimWindowPtr;
      layerValues = cell2mat(obj.LayersByStim.values());
      Screen('BeginOpenGL', win);
      vis.draw(win, obj.Occ, layerValues, obj.TextureById);
      Screen('EndOpenGL', win);
    end
    
    function activateEventHandler(obj, handler, eventInfo, dueTime)
      activate(handler, eventInfo, dueTime);
      % if the handler requests the stimulus window be invalided, do so.
      if handler.InvalidateStimWindow
        obj.StimWindow.invalidate;
      end
    end
    
    function saveData(obj)
        % save the data to the appropriate locations indicated by expRef
        savepaths = dat.expFilePath(obj.Data.expRef, 'block');
        superSave(savepaths, struct('block', obj.Data));
        
        % if this is a 'ChoiceWorld' experiment, let's save out for
        % relevant data for basic behavioural analysis and register them to
        % Alyx
        if contains(lower(obj.Data.expDef), 'choiceworld')
          % Write feedback
          feedback = obj.Data.events.feedbackValues;
          feedback(feedback == 0) = -1;
          alf.writeEventseries(savepaths{1}, 'cwFeedback', feedback);
          alf.writeTimeseries(savepaths{1}, 'cwFeedback',...
            obj.Data.events.feedbackTimes);
          % Write go cue
          
          % Write response
          
          % Write stim on times
          alf.writeEventseries(savepaths{1}, 'cwStimOn', obj.Data.events.stimulusOn);
          alf.writeTimeseries(savepaths{1}, 'cwStimOn', obj.Data.events.stimulusOn);
          
          % Write trial intervals
          alf.writeInterval(savepaths{1}, 'cwTrials',...
            obj.Data.events.newTrialValues, obj.Data.events.endTrialValues);
          repNum = obj.Data.events.repeatNumValues;
          alf.writeEventseries(savepaths{1}, 'cwTrials.inclTrials', repNum == 1);
          alf.writeEventseries(savepaths{1}, 'cwTrials.repNum', repNum);
          
          % Write wheel times, position and velocity
          wheelValues = obj.Data.events.inputs.wheelValues;
          wheelTimes = obj.Data.events.inputs.wheelTimes;
          alf.writeEventseries(savepaths{1}, 'cwWheel.position', wheelValues);
          alf.writeTimeseries(savepaths{1}, 'cwWheel', wheelTimes);
          alf.writeEventseries(savepaths{1}, 'cwWheel.velocity', wheelValues./wheelTimes);
          
          % Register them to Alyx
        end
          
        if isempty(obj.AlyxInstance)
            warning('No Alyx token set');
        else
            try
                [subject,~,~] = dat.parseExpRef(obj.Data.expRef); 
                if strcmp(subject,'default'); return; end
                % Register saved files
                alyx.registerFile(savepaths{end}, 'mat',...
                    obj.AlyxInstance.subsessionURL, 'Block', [], obj.AlyxInstance);
                % Save the session end time
                alyx.putData(obj.AlyxInstance, obj.AlyxInstance.subsessionURL,...
                    struct('end_time', alyx.datestr(now), 'subject', subject));
            catch ex
                warning('couldnt register files to alyx');
                disp(ex)
            end
        end

    end
  end
  
end
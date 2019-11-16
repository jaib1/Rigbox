classdef (Sealed) SignalsTest < handle %& exp.SignalsExp
  %SIGNALSTEST A GUI for testing SignalsExp experiment definitions
  % TODO This may be generalized for all Experiment classes!
  % See also: EXP.SIGNALSEXPTEST, EUI.MCONTROL
  %
  
  % can be set in GUI or command line to improve visualization
  properties
    Hardware
    Ref
    LoggingDisplay % window within Parent for showing log output
  end
  
  properties
    % Option for live-plotting signals during experiment
    LivePlot matlab.lang.OnOffSwitchState = 'off'
    % Option for showing ExpPanel defined by 'expPanelFun' parameter
    ShowExpPanel matlab.lang.OnOffSwitchState = 'on'
    % Option for viewing PTB window as a single screen
    SingleScreen matlab.lang.OnOffSwitchState = 'off'
  end
  
  properties (Transient, SetAccess = private)
    % The Signals experiment object
    Experiment exp.test.Signals
    % The parameter editor GUI
    ParamEditor eui.ParamEditor
    % Handle to figure for live-plotting signals
    LivePlotFig matlab.ui.Figure
    ExpPanel eui.ExpPanel
  end
  
  properties (Dependent)
    IsRunning
  end
  
  properties (Access = private)
    % The path of the last selected experiment function
    LastDir
    % The currently chosen Signals experiment definition
    ExpDef function_handle
    % Dummy communicator for ExpPanel events.  Our experiment object may
    % notify the ExpPanel through dummy events.
    DummyRemote srv.StimulusControl
    % The parent figure for the GUI
    Parent matlab.ui.Figure
    % A list of saved parameters sets
    ParameterSets bui.Selector
    % Verticle container for the ParamEditor
    ParamPanel
    % Current parameter set label
    ParamProfileLabel
    % Handles for the ExpPanel and ParamEditor events
    Listeners
    
    % The container for the running experiment panel
    ExpPanelBox
    RefreshTimer
    MainGrid % main 'uix.GridFlex' object
    ExpGrid % top 'uix.Grid' object; child of 'MainGrid'
    ExpTopBox % 'uix.HBox' object, containing UI elements to run the expDef; child of 'ExpGrid'
    SelectExpDef % handle to 'Select Signals Exp Def' push-button
    OptionsButton % handle to 'Options' push-button
    StartButton % handle to 'Start' push-button
  end
  
  events
    UpdatePanel
  end
  
  
  methods
    
    function TF = get.IsRunning(obj)
      TF = ...
        ~isempty(obj.Experiment) && ...
        isvalid(obj.Experiment) && ...
        obj.Experiment.IsLooping;
    end
    
    function obj = SignalsTest(expdef, rig)
      %SIGNALSTEST Creates a GUI for testing SignalsExp experiments
      % constructor method runs the 'buildUI' method to create the ExpTest
      % panel
      PsychDebugWindowConfiguration % TODO Remove
      InitializeMatlabOpenGL
      % Check paths file exists
      assert(exist('+dat/paths', 'file') == 2, ...
        'signals:test:copyPaths',...
        'No paths file found. A template can be found in %s.', ...
        fullfile(fileparts(which('addRigboxPaths')), 'docs', 'setup'))
      
      obj.LastDir = getOr(dat.paths, 'expDefinitions');
      if nargin > 0 % called with experiment function to run
        if ischar(expdef)
          % Check function exists
          % TODO bump down to warning
          assert(exist(expdef, 'file') == 2, ...
            'rigbox:eui:SignalsTest:fileNotFound',...
            'File function ''%s.m'' not found.', expdef)
          obj.LastDir = fileparts(which(expdef));
          obj.ExpDef = fileFunction(expdef);
        else
          obj.ExpDef = expdef;
          expdefname = func2str(expdef);
        end
      else
        % Prompt for experiment definition
        [mfile, mpath] = uigetfile(...
          '*.m', 'Select the experiment definition function', obj.LastDir);
        if mfile == 0
          return
        end
        obj.LastDir = mpath;
        [~, expdefname] = fileparts(mfile);
        obj.ExpDef = fileFunction(mpath, mfile);
      end
      
      obj.buildUI % Build the GUI
      obj.Parent.Name = expdefname; % Set title
      
      if nargin < 2 % Make a rig object
        % Configure a stimulus window
        obj.Hardware.stimWindow = hw.debugWindow(false);
        obj.Hardware.stimWindow.BackgroundColour = 255/2;
        obj.Hardware.stimWindow.OpenBounds = [0,0,960,400];
        
        if obj.SingleScreen % view PTB window as single-screen
          center = [0 0 0];
          viewingAngle = 0;
          dimsCM = [20 20];
          pxBounds = [0 0 400 400];
          screen = vis.screen(center, viewingAngle, dimsCM, pxBounds);
        else
          screenDimsCm = [20 25];
          pxW = 960/3; % 3 screens % 1280
          pxH = 400; % 600
          screen(1) = vis.screen([0 0 9.5], -90, screenDimsCm, [0 0 pxW pxH]); % left screen
          screen(2) = vis.screen([0 0 10],  0 ,...
            screenDimsCm, [pxW 0 2*pxW pxH]); % ahead screen
          screen(3) = vis.screen([0 0 9.5],  90,...
            screenDimsCm, [2*pxW  0 3*pxW pxH]); % right screen
        end
        obj.Hardware.screens = screen;
        
        %       obj.Hardware.mouseInput = hw.CursorPosition;
        obj.Hardware.mouseInput.readAbsolutePosition = @obj.getMouse;
        obj.Hardware.mouseInput.MillimetresFactor = .1;
        obj.Hardware.mouseInput.EncoderResolution = 1;
        obj.Hardware.mouseInput.ZeroOffset = 0;
        obj.Hardware.mouseInput.zero = @nop;
        
        obj.Hardware.daqController = hw.DaqController;
        obj.Hardware.name = hostname;
        obj.Hardware.clock = hw.ptb.Clock;
        
        InitializePsychSound
        d = PsychPortAudio('GetDevices');
        d = d([d.NrOutputChannels] == 2);
        [~,I] = min([d.LowOutputLatency]);
        obj.Hardware.audioDevices = d(I);
        obj.Hardware.audioDevices.DeviceName = 'default';
      else
        obj.Hardware = rig;
      end
      tc = matlab.mock.TestCase.forInteractiveUse;
      [obj.DummyRemote, behaviour] = tc.createMock(?srv.StimulusControl);
      when(withAnyInputs(behaviour.quitExperiment), ...
        matlab.mock.actions.Invoke(@(~,TF)obj.Experiment.quit(TF))); % FIXME Call startStopExp method instead
      % Keep TestCase around until cleanup
      addlistener(obj, 'ObjectBeingDestroyed', @(~,~)delete(tc));
      cb = @(~,e) iff(strcmp(e.Name,'update'), @()obj.log('Experiment update: %s', e.Data{2}), @nop);
      addlistener(obj.DummyRemote, 'ExpUpdate', cb);
      obj.DummyRemote.Name = obj.Hardware.name;
      obj.Ref = dat.constructExpRef('test', now, 1);
      
      obj.loadParameters('<defaults>')
    end
    
    
    function paramProfileChanged(obj, src, ~)
      % callback for user GUI-selected parameter profile
      if isa(src, 'eui.ParamEditor') % if a change was made to a single parameter
        return
      end
      profile = cell2mat(src.Option(src.SelectedIdx));
      obj.loadParameters(profile);
    end
    
    function setOptions(obj, ~, ~)
      % callback for 'Options' button: sets options for running the Exp Def:
      % 1) yes/no for live-plotting; 2) yes/no for saving a block file
      
      [~,~,w] = distribute(pick(groot, 'ScreenSize'));
      %       getnicedialoglocation_for_newid([300 250], 'pixels')
      dh = dialog('Position', [w/2, 100, 300 250], 'Name', ...
        'Exp Test Options', 'WindowStyle', 'normal');
      dCheckBox = uix.VBox('Parent', dh, 'Padding', 10);
      livePlotCheck = uicontrol('Parent', dCheckBox, 'Style', 'checkbox',...
        'TooltipString', 'Plot events signals as they update', ...
        'String', 'Plot Signals', 'Value', logical(obj.LivePlot));
      expPanelCheck = uicontrol('Parent', dCheckBox, 'Style', 'checkbox',...
        'TooltipString', 'Display an experiment panel', ...
        'String', 'Show experiment panel', 'Value', logical(obj.ShowExpPanel));
      SingleScreenCheck = uicontrol('Parent', dCheckBox, 'Style', 'checkbox',...
        'String', 'View PTB Window as Single Screen', ...
        'TooltipString', 'Simuluate a single screen monitor', ...
        'Value', logical(obj.SingleScreen), 'Enable', 'off');
      parslist = obj.Listeners(arrayfun(@(o)isa(o.Source{1}, 'eui.ParamEditor'), obj.Listeners));
      updateParsOnEdit = uicontrol('Parent', dCheckBox, 'Style', 'checkbox', ...
        'String', 'Post new parameters on edit', ...
        'TooltipString', 'Update parameter signals each time a field is changed', ...
        'Value', ~isempty(parslist) && parslist(1).Enabled);
      CloseHBox = uix.HBox('Parent', dCheckBox, 'Padding', 10);
      uicontrol('Parent', CloseHBox, 'String', 'Save and Close', ...
        'Callback', @(~,~) processOptions);
      
      function processOptions
        % callback function for the 'Save and Close' button defined above
        % TODO use setters instead
        
        % Configure live plot
        obj.LivePlot = livePlotCheck.Value;
        figValid =  ~isempty(obj.LivePlotFig) && isvalid(obj.LivePlotFig);
        if obj.LivePlot && obj.IsRunning && figValid == false
          % If the experiment is running and we want to show figure...
          plot(obj) % ... create new plot
        elseif ~obj.LivePlot && figValid
          % If the figure is open and we chose not to plot...
          close(obj.LivePlotFig) % ... close the figure
        end
        
        % Configure the ExpPanel
        obj.ShowExpPanel = expPanelCheck.Value;
        if ~obj.ShowExpPanel % Hide the panel
          obj.ExpPanelBox.Visible = false;
          obj.ExpPanelBox.Parent.set('Widths', [-1, 0]);
        else % If an experiment is running, show panel, otherwise done by init
          if obj.IsRunning
            obj.ExpPanelBox.Visible = true;
            obj.ExpPanelBox.Parent.set('Widths', [-1, 400]);
          end
        end
        
        % Configure default screen settings
        if obj.SingleScreen ~= SingleScreenCheck.Value
          % TODO Make changes to screens field
        end
        obj.SingleScreen = SingleScreenCheck.Value;
        
        % Configure Parameter update callback
        if isempty(parslist)
          % Regardless of setting, create a listener for eui.ParamEditor
          % Changed event
          runOnValid = @(fn) iff(~isempty(obj.Experiment), fn, @nop);
          callbk = @(PE,~) ...
            runOnValid(@()obj.Experiment.updateParams(PE.Parameters.Struct));
          log = @()obj.log('Updating parameters');
          parslist = [addlistener(obj.ParamEditor, 'Changed', callbk);
            addlistener(obj.ParamEditor, 'Changed', @(~,~)runOnValid(log))];
          obj.Listeners = [obj.Listeners; parslist];
        end
        [parslist.Enabled] = deal(updateParsOnEdit.Value);
        delete(dh)
      end
      
    end
    
    function startStopExp(obj)
      % callback for 'Start/Stop' button:
      % stops experiment if running, and starts experiment if not running
      
      if obj.IsRunning
        % Stop experiment
        obj.log('Stopping experiment');
        obj.Experiment.quit;
        %         if obj.LivePlot && ~isempty(obj.LivePlotFig) && isvalid(obj.LivePlotFig)
        %           obj.LivePlotFig.DeleteFcn(); % Clear plot listeners
        %         end
        obj.stopTimer
        
        obj.StartButton.set('String', 'Start');
      else % start experiment
        % FIXME Log via event handlers
        %         obj.Experiment.updateParameters %(?)
        obj.StartButton.set('String', 'Stop');
        obj.init
        obj.log('Starting ''%s'' experiment.  Press <%s> to pause', ...
          obj.Parent.Name, KbName(obj.Experiment.PauseKey));
        try % TODO Stop timer?
          obj.Experiment.run(obj.Ref);
        catch ex
          % Experiment stopped with an exception
          % Notify panel and stop timer
          evt = srv.ExpEvent('exception', obj.Ref, ex.message);
          notify(obj.DummyRemote, 'ExpStopped', evt);
          obj.stopTimer
        end
      end
      
    end
    
    function log(obj, varargin)
      % LOG Displayes timestamped information about occurrences in mc
      %   The log is stored in the LoggingDisplay property.
      % log(formatSpec, A1,... An)
      %
      % See also FPRINTF
      message = sprintf(varargin{:});
      timestamp = datestr(now, 'dd-mm-yyyy HH:MM:SS');
      str = sprintf('[%s] %s', timestamp, message);
      current = get(obj.LoggingDisplay, 'String');
      set(obj.LoggingDisplay, 'String', [current; str], 'Value', numel(current) + 1);
    end
    
    function clearLog(obj)
      % clears 'LoggingDisplay'
      obj.LoggingDisplay.String = {};
    end
    
    function cleanup(obj)
      if obj.IsRunning
        obj.Experiment.quit(true);
      end
      obj.Hardware.stimWindow.close()
      if ~isempty(obj.RefreshTimer)
        obj.stopTimer()
        delete(obj.RefreshTimer);
        obj.RefreshTimer = [];
      end
      if obj.LivePlot && ~isempty(obj.LivePlotFig) && isvalid(obj.LivePlotFig)
        obj.LivePlotFig.DeleteFcn(); % Clear plot listeners
      end
      obj.Listeners = [];
    end
    
    function delete(obj)
      % makes sure to delete 'ScreenH' PTB Screen and 'LivePlot' figure
      fprintf('delete called on SignalsTest\n');
      cleanup(obj)
      obj.Experiment = exp.test.Signals.empty;
      if ~isempty(obj.LivePlotFig) && isvalid(obj.LivePlotFig)
        delete(obj.LivePlotFig)
      end
      delete(obj.Hardware.stimWindow)
    end
    
    function set.Experiment(obj, experiment)
      % TODO This should be a cleanup method instead so we can handle any
      % listeners
      if obj.IsRunning
        % FIXME Currently when the window is closed the experiment object
        % is quit and deleted during the main loop's call to drawnow.
        % After deletion the function continues throwing an error about
        % access to a deleted object
        obj.Experiment.quit(true);
        %         drawnow nocallbacks
        %         waitfor(obj.Experiment,'IsLooping',false)
      end
      delete(obj.Experiment)
      obj.Experiment = experiment;
    end
    
  end
  
  methods (Access = protected)
    
    function buildUI(obj)
      % Create Exp Test Panel figure and all UI elements:
      % Layout arrangement: 'Parent' -> 'MainGrid' ->
      %
      % See also loadParameters
      
      [~,~,w,h] = distribute(pick(groot, 'ScreenSize'));
      
      % create main figure
      obj.Parent = figure('Name', 'ExpTestPanel', 'NumberTitle', 'off',...
        'Toolbar', 'None', 'Menubar', 'None', 'Position', [w/2-350,...
        h/2-475, 950, 700], 'DeleteFcn', @(~,~) obj.cleanup);
      
      % GUI layout toolbox functions to set-up ui elements within main figure
      panel = uix.HBox('Parent', obj.Parent, 'Padding', 5);
      obj.MainGrid = uix.GridFlex('Parent', panel, 'Spacing', 10,...
        'Padding', 5);
      obj.ExpPanelBox = uix.VBox('Parent', panel, 'Padding', 5, 'Visible', 0);
      panel.set('Widths', [-1, 0])
      obj.ExpGrid = uix.Grid('Parent', obj.MainGrid, 'Spacing', 5,...
        'Padding', 5);
      obj.ExpTopBox = uix.HBox('Parent', obj.ExpGrid, 'Spacing', 5,...
        'Padding', 5);
      
      obj.SelectExpDef = uicontrol('Parent', obj.ExpTopBox,...
        'Style', 'pushbutton', 'String', 'Select Signals Exp Def',...
        'Callback', @(~,~)obj.setExpDef());
      obj.OptionsButton = uicontrol('Parent', obj.ExpTopBox,...
        'Style', 'pushbutton', 'String', 'Options',...
        'Callback', @(src,event) obj.setOptions(src,event));
      obj.StartButton = uicontrol('Parent', obj.ExpTopBox,...
        'Style', 'pushbutton', 'String', 'Start',...
        'Callback', @(~,~)obj.startStopExp());
      
      % Parameters Panel
      param = uix.Panel('Parent', obj.MainGrid,...
        'Title', 'Parameters', 'Padding', 5);
      obj.ParamPanel = uiextras.VBox('Parent', param, 'Padding', 5); % Make verticle container for parameters
      
      hbox = uiextras.HBox('Parent', obj.ParamPanel); % Make container for 'sets' dropdown boxes
      bui.label('Current set:', hbox); % Add 'Current set' label
      obj.ParamProfileLabel = bui.label('none', hbox, 'FontWeight', 'bold'); % Current parameter label
      hbox.Sizes = [60 400]; % Set size of Current set labels
      hbox = uiextras.HBox('Parent', obj.ParamPanel, 'Spacing', 2); % Make new HBox for saved sets
      bui.label('Saved sets:', hbox);  % Add 'Saved sets' label
      obj.ParameterSets = bui.Selector(hbox, ...
        [{'<defaults>'}; fieldnames(dat.loadParamProfiles('custom'))]);
      %       obj.ParameterSets.addlistener('SelectionChanged', obj.paramProfileChanged(src, event));
      uicontrol('Parent', hbox,... % Make 'Load' button
        'Style', 'pushbutton',...
        'String', 'Load',...
        'Callback', @(~,~) obj.loadParameters(obj.ParameterSets.Selected)); % Pass selected param profile to loadParamProfile() when pressed
      uicontrol('Parent', hbox,... % Make 'Save' button
        'Style', 'pushbutton',...
        'String', 'Save...',...
        'Callback', @(~,~)obj.saveParamProfile,...
        'Enable', 'on');
      uicontrol('Parent', hbox,... % Make 'Delete' button
        'Style', 'pushbutton',...
        'String', 'Delete...',...
        'Callback', @(~,~)obj.delParamProfile,...
        'Enable', 'on');
      hbox.Sizes = [60 200 60 60 60]; % Set horizontal sizes for Sets dropdowns and buttons
      obj.ParamPanel.Sizes = [22 22]; % Set vertical size by changing obj.ParamPanel VBox size
      
      % Logging Display
      obj.LoggingDisplay = uicontrol('Parent', obj.MainGrid,...
        'Style', 'listbox', 'Enable', 'inactive', 'String', {},...
        'Tag', 'Logging Display');
      c = uicontextmenu(obj.Parent);
      obj.LoggingDisplay.UIContextMenu = c;
      uimenu(c, 'Label', 'Clear Logging Display',...
        'MenuSelectedFcn', @(~,~) obj.clearLog);
      
      % Set proportions
      obj.MainGrid.set('Heights', [-1 -9 -3]);
      
      % Add a timer for updating the panel.  NB: Although we could call
      % obj.ExpPanel.update() directly, events throw errors as warnings
      % providing us with more information for debugging!
      obj.RefreshTimer = timer(...
        'Name', 'ExpPanel update', ...
        'Period', 0.1, ...
        'ExecutionMode', 'fixedSpacing',...
        'TimerFcn', @(~,~)obj.notify('UpdatePanel'));
    end
        
    function init(obj)
      % INIT Initialize experiment object
      %  Instantiate an experiment object and configure the live plot and
      %  ExpPanel
      
      % Set up experiment
      if ~obj.Hardware.stimWindow.IsOpen
        obj.Hardware.stimWindow.PxDepth = Screen('PixelSize', 0);
        obj.Hardware.stimWindow.open();
      end
      p = obj.ParamEditor.Parameters.Struct;
      p.defFunction = obj.ExpDef;
      obj.Experiment = exp.test.Signals(p, obj.Hardware); % create new SignalsExp object
      
      % Switch off keypresses
      obj.Experiment.QuitKey = [];
      
      % Add in our dummy communicator
      obj.Experiment.Communicator = obj.DummyRemote;
      
      if obj.LivePlot
        plot(obj)
      end
      
      if obj.ShowExpPanel
        % If there's a previous panel, delete it
        if ~isempty(obj.ExpPanel)
          delete(obj.ExpPanel)
        end
        obj.ExpPanel = eui.ExpPanel.live(obj.ExpPanelBox, obj.Ref, obj.DummyRemote, p);
        hidePanel = @(~,~)fun.apply({ % TODO Turn off param too
          @()set(obj.ExpPanelBox, 'Visible', false);
          @()set(obj.ExpPanelBox.Parent, 'Widths', [-1, 0])});
        obj.Listeners = [obj.Listeners
          event.listener(obj, 'UpdatePanel', @(~,~)obj.ExpPanel.update())
          event.listener(obj.ExpPanel, 'ObjectBeingDestroyed', hidePanel) % FIXME No need to keep around
          event.listener(obj.ExpPanel, 'ObjectBeingDestroyed', @(~,~)obj.stopTimer)];
        if strcmp(obj.ExpPanelBox.Visible, 'off')
          obj.ExpPanelBox.Visible = true;
          set(get(obj.ExpPanelBox, 'Parent'), 'Widths', [-1, 400])
        end
        start(obj.RefreshTimer);
      end
      % TODO Set as callback?
      % Update the parameter set label to indicate used for this experiment
      %       parLabel = sprintf('from last experiment of %s (%s)', subject, expRef);
      %       set(obj.ParamProfileLabel, 'String', parLabel, 'ForegroundColor', [0 0 0]);
    end
    
    function stopTimer(obj)
      % STOPTIMER Convenience function only stops timer when running
      if ~isempty(obj.RefreshTimer) && strcmp(obj.RefreshTimer.Running, 'on')
        stop(obj.RefreshTimer);
      end
    end
    
    function plot(obj)
      % PLOT Set up figure for online plotting of Signals events
      %  If the current plotting figure is no longer valid a new one is
      %  created.
      %
      % See also SIG.TEST.TIMEPLOT
      if isempty(obj.LivePlotFig) || ~isvalid(obj.LivePlotFig)
        obj.LivePlotFig = figure('Name', 'LivePlot', 'NumberTitle', 'off', ...
          'Color', 'w', 'Units', 'normalized');
        obj.LivePlotFig.OuterPosition = [0.6 0 0.4 1];
      else
        obj.LivePlotFig.DeleteFcn(); % Delete previous listeners
      end
      sig.test.timeplot(obj.Experiment.Time, obj.Experiment.Events, ...
        'parent', obj.LivePlotFig, 'mode', 0, 'tWin', 60);
    end
    
    function x = getMouse(obj)
      % GETMOUSE Return mouse x co-ordinate over stimulus window only
      %  TODO Make into hw class
      persistent last lastInBounds
      if isempty(last); last = 0; end
      if isempty(lastInBounds); lastInBounds = 0; end
      bounds = obj.Hardware.stimWindow.OpenBounds;
      [x,y] = GetMouse();
      withinBounds = ...
        x >= bounds(1) && ...
        x <= bounds(1) + bounds(3) && ...
        y >= bounds(2) && ...
        y <= bounds(2) + bounds(4);
      
      dx = (x - last);
      last = x;
      if withinBounds
        x = lastInBounds + dx;
        lastInBounds = x;
      else
        x = lastInBounds;
      end
    end
    
    function setExpDef(obj)
      % gets and sets signals expDef
      [mfile, mpath] = uigetfile('*.m', 'Select Exp Def', obj.LastDir);
      if ~mfile, return; end
      obj.ExpDef = fileFunction(mpath, mfile);
      obj.Parent.Name = mfile(1:end-2);
      obj.loadParameters('<defaults>');
    end
    
    function loadParameters(obj, profile)
      % loads parameters
      %
      % Inputs:
      %   'profile': the parameters' profile (i.e. a parameter set)
      
      % Red 'Loading...' while new set loads
      set(obj.ParamProfileLabel, 'String', 'loading...', 'ForegroundColor', [1 0 0]);
      
      % switch-case for how to load parameters for either: 1) default Exp
      % Def parameters; 3) Saved parameter set on server
      switch lower(profile)
        case '<defaults>'
          paramStruct = exp.inferParameters(obj.ExpDef);
          label = 'defaults';
        otherwise
          saved = dat.loadParamProfiles('custom');
          paramStruct = saved.(profile);
          label = profile;
      end
      
      if isfield(paramStruct, 'services') % remove 'services' field
        paramStruct = rmfield(paramStruct, 'services');
      end
      %       paramStruct = rmfield(paramStruct, 'defFunction');
      
      pars = exp.Parameters(paramStruct); % build parameters
      % Now parameters are loaded, pass to ParamEditor for display, etc.
      if isempty(obj.ParamEditor)
        obj.ParamEditor = eui.ParamEditor(pars, obj.ParamPanel);
      else
        obj.ParamEditor.buildUI(pars);
      end
      obj.ParamEditor.addlistener('Changed', @(src,event) obj.paramProfileChanged(src, event));
      set(obj.ParamProfileLabel, 'String', label, 'ForegroundColor', [0 0 0]);
    end
    
    function saveParamProfile(obj)
      % Called by 'Save...' button press, save a new parameter profile
      selProfile = obj.ParameterSets.Selected; % Find which set is currently selected
      % This statement is for autofilling the save as input dialog; default
      % value is currently selected profile name, however if a special case
      % profile is selected there is no default value
      def = iff(selProfile(1) ~= '<', selProfile, '');
      ipt = inputdlg('Enter a name for the parameters profile', 'Name', 1, {def});
      if isempty(ipt)
        return
      else % Get the name they entered into the dialog
        name = ipt{1};
      end
      doSave = true;
      validName = matlab.lang.makeValidName(name);
      if ~strcmp(name, validName) % If the name they entered is non-alphanumeric...
        q = sprintf('''%s'' is not valid (names must be alphanumeric with no spaces)\n', name);
        q = [q sprintf('Do you want to use ''%s'' instead?', validName)];
        doSave = strcmp(questdlg(q, 'Name', 'Yes', 'No', 'No'),  'Yes'); % Do they still want to save with suggested name?
      end
      if doSave % Going ahead with save
        p = obj.ParamEditor.Parameters.Struct;
        dat.saveParamProfile('custom', validName, p); % Save
        %add the profile to the control options
        profiles = obj.ParameterSets.Option;
        if ~any(strcmp(obj.ParameterSets.Option, validName))
          obj.ParameterSets.Option = [profiles; validName]; % Add to list
        end
        obj.ParameterSets.Selected = validName; % Make currently selected
        %set label for loaded profile
        set(obj.ParamProfileLabel, 'String', validName, 'ForegroundColor', [0 0 0]);
        obj.log('Saved parameters as ''%s''', validName);
      end
    end
    
    function delParamProfile(obj)
      % Called when 'Delete...' button is pressed next to saved sets
      profile = obj.ParameterSets.Selected; % Get param profile that was selected from the dropdown?
      assert(profile(1) ~= '<', 'Special case profile %s cannot be deleted', profile); % If '<last for subject>' or '<defaults>' is selected give error
      q = sprintf('Are you sure you want to delete parameters profile ''%s''', profile);
      doDelete = strcmp(questdlg(q, 'Delete', 'Yes', 'No', 'No'),  'Yes'); % Find out whether they confirmed delete
      if doDelete % They pressed 'Yes'
        dat.delParamProfile('custom', profile);
        %remove the profile from the control options
        profiles = obj.ParameterSets.Option; % Get parameter profile
        obj.ParameterSets.Option = profiles(~strcmp(profiles, profile)); % Set new list without deleted profile
        % log the parameters as being deleted
        obj.log('Deleted parameter set ''%s''', profile);
      end
    end
    
  end
  
end
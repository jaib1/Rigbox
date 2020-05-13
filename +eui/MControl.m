classdef MControl < handle
  %EUI.MCONTROL Master Control
  %   Whatever it is, take control of your experiments from this GUI
  %   This code is a bit messy and undocumented. 
  %   TODO: 
  %     - improve it.
  %     - ensure all Parent objects specified explicitly (See GUI Layout
  %     Toolbox 2.3.1/layoutdoc/Getting_Started2.html)
  %   See also MC, EUI.ALYXPANEL, EUI.EXPPANEL, EUI.LOG, EUI.PARAMEDITOR
  %
  % Part of Rigbox
  
  % 2013-03 CB created
  % 2017-02 MW Updated to work with new GUILayoutToolbox
  % 2017-02 MW Changed expFactory to allow loading of last params for the
  % specific expDef that was selected
  
  % @TODO set properties attributes
  properties
    % struct containing all availiable experiment frameworks and function
    % handles to constructors for their default parameters and classes
    NewExpFactory
    % `uiextras.VBox` object containing *all* ui elements in the mc gui
    RootContainer
    % `uiextras.TabPanel` object containing the 'Log' and 'Experiment' tabs
    TabPanel 
    % `uicontrol` listbox object for showing log output during experiments
    LoggingDisplay
    % `uiextras.TabPanel` object containing the 'New' and 'Current' tabs
    % in the 'Experiment' tab
    ExpTabs
    % `bui.selector` dropdown menu object for selecting a subject in the
    % 'Experiments' - 'New' tab
    NewExpSubjects
    % An array of `srv.StimulusControl` objects with connection information
    % for each remote rig in the 'Experiments' - 'New' tab
    RemoteRigs 
    % Listener functions for the mc gui for reading from the scale and
    % getting status updates from `RemoteRigs`
    Listeners
    % `bui.selector` dropdown menu object for selecting an exp framework
    % in the 'Experiments' - 'New' tab
    ExpFrameworks
    % `bui.selector` dropdown menu object for selecting an exp def in the
    % 'Experiments' - 'New' tab
    ExpDefs
    % 'Options' button that opens the rig options dialog box in the
    % 'Experiments' - 'New' tab
    RigOptionsButton
    % 'Start' button that begins an experiment in the
    % 'Experiments' - 'New' tab
    BeginExpButton
    % `eui.AlyxPanel` object for interfacing with alyx database directly
    % within mc gui in the 'Experiments' - 'New' tab
    AlyxPanel
    % `uiextras.VBox` object containing info on parameter sets in the
    % 'Experiments' - 'New' tab
    ParamPanel
    % `bui.label` object containing the name of the selected parameter set
    % in the 'Experiments' - 'New' tab
    ParamProfileLabel
    % `bui.selector` dropdown menu object for selecting a parameter set in
    % the 'Experiments' - 'New' tab
    ParamProfiles
    % `exp.Parameters` object containing the selected parameter set
    Parameters
    % `eui.ParamEditor` gui object for visualizig and editing parameters in
    % the selected parameter set
    ParamEditor
    % `uiextras.Grid` object containing a panel for each running experiment
    % in the 'Experiments' - 'Current' tab
    ActiveExpsGrid
    % `eui.Log` object for setting the 'Log' tab
    Log
    % `uiextras.TabPanel` object containing the 'Entries' and 'Weight' tabs
    % in the 'Log' tab
    LogTabs
    % `bui.selector` dropdown menu object for selecting a subject in the
    % 'Log' tab
    LogSubjects
    % `bui.axes` object that holds the axes for the weight plots in the
    % 'Log' tab
    WeightAxes
    % scatter object displayed in `WeightAxes` for plotted weight info
    WeightReadingPlot
    % 'Record' button for entering subject weight in 'Log' - 'Weight' tab
    RecordWeightButton
    % timer set to regularly execute the 'Refresh' event 
    RefreshTimer
    % `hw.WeighingScale` object for interacting with a scale
    WeighingScale
    % `uicontrol` edit text boxes for setting pre (i=1) and post (i=2)
    % experiment delays; pops up when clicking `RigOptionsButton`
    PrePostExpDelayEdits
    % `eui.ExpPanel` object for a running experiment in the 'Experiments'
    % - 'Current' tab
    LastExpPanel
  end
  
  events
    % refreshes/updates plots
    Refresh
  end
  
  % @TODO set methods attributes
  methods
 
    function obj = MControl(parent)
    % `parent` is a figure object
      obj.NewExpFactory = struct(...
        'label',...
        {'ChoiceWorld' 'DiscWorld' 'GaborMapping' ...
        'BarMapping' 'SurroundChoiceWorld' '<custom...>'},...
        'matchTypes', {{'ChoiceWorld' 'SingleTargetChoiceWorld'},...
        {'DiscWorld'},...
        {'GaborMapping'},...
        {'BarMapping'},...
        {'SurroundChoiceWorld'},...
        {'custom' ''}},...
        'defaultParamsFun',...
        {@exp.choiceWorldParams, @exp.discWorldParams,...
        @exp.gaborMappingParams,...
        @exp.barMappingParams, @()exp.choiceWorldParams('Surround'),...
        @exp.inferParameters});
      
      % struct containing all experiment frameworks organized by four
      % fields: 'label' (the name of the framework), 'matchTypes' (the
      % names of matching parameter sets), 'defaultParamsFun' (the function
      % called to set up the default parameter set for the given framework,
      % and 'defaultClass' (the class used to set-up the given framework)
      obj.NewExpFactory =... 
        struct(...
          'label', {'signals'},...
          'matchTypes', {{'signals', 'custom'}},...
          'defaultParamsFun', {@exp.inferParameters},...
          'defaultClass', {@exp.SignalsExp});
      % build the ui for the gui
      obj.buildUI(parent);
      set(obj.RootContainer, 'Visible', 'on');
      obj.Parameters = exp.Parameters;
      %obj.LogSubjects.Selected = '';
      obj.NewExpSubjects.Selected = 'default'; % Make default selected subject 'default'
      %obj.expTypeChanged();
      rig = hw.devices([], false);
      obj.RefreshTimer = timer('Period', 0.1, 'ExecutionMode', 'fixedSpacing',...
        'TimerFcn', @(~,~)notify(obj, 'Refresh'));
      start(obj.RefreshTimer);
      addlistener(obj.AlyxPanel, 'Connected', @obj.expSubjectChanged);
      addlistener(obj.AlyxPanel, 'Disconnected', @obj.expSubjectChanged);
      try
        if isfield(rig, 'scale') && ~isempty(rig.scale)
          obj.WeighingScale = getOr(rig, 'scale');
          init(obj.WeighingScale);
          % Add listners for new reading, both for the log tab and also for
          % the weigh button in the Alyx Panel.
          obj.Listeners = [obj.Listeners,...
            {event.listener(obj.WeighingScale, 'NewReading', @obj.newScalesReading)}...
            {event.listener(obj.WeighingScale, 'NewReading', @(src,evt)obj.AlyxPanel.updateWeightButton(src,evt))}];
        end
      catch
        obj.log('Warning: could not connect to weighing scales');
      end    
    end
    
    function buildUI(obj, parent)
    % `parent` is a figure object
    %
    % UI Layout:
    % ----------
    % Root Container `obj.RootContainer`
    %   Root Container Tabs `obj.TabPanel`
    %     Experiments Tab `obj.ExpTabs`
    %       New Tab `newExpBox`
    %         Header Box `headerBox`
    %           Exp Select box `expSelectBox`
    %           Subject, Rig, Exp Framework, Exp Def labels
    %             Exp Select grid `expSelectGrid`
    %               Subject, Rig, Exp Framework, Exp Def dropdowns
    %               Options, Start buttons
    %           Alyx Panel `obj.AlyxPanel`
    %           
    %         Params Panel `param`
    %       Current Tab `runningExpBox`
    %     Log Tab
        
      % Container for all UI objects in the MC GUI
      obj.RootContainer = uiextras.VBox('Parent', parent,...
        'DeleteFcn', @(~,~) obj.cleanup(), 'Visible', 'on');

      % The main tab panel, which will contain the 'Experiments' and 'Log'
      % tabs
      obj.TabPanel = uiextras.TabPanel('Parent', obj.RootContainer, 'Padding', 5);

      % The message area at the bottom of the MC GUI
      obj.LoggingDisplay =...
        uicontrol('Parent', obj.RootContainer, 'Style', 'listbox',...
                  'Enable', 'inactive', 'String', {},...
                  'Tag', 'Logging Display');

      % The `TabPanel` size will vary as a function of the figure size,
      % while the `LoggingDisplay` size has a fixed height of 100 px
      obj.RootContainer.Sizes = [-1 100];
      
      % Experiment tabs, which will contain the 'New' and 'Current'
      % experiments tabs
      obj.ExpTabs = uiextras.TabPanel('Parent', obj.TabPanel);
      
      % A box in the 'Experiments' tab, which will contain everything
      % needed to start a new experiment
      newExpBox = uiextras.VBox('Parent', obj.ExpTabs, 'Padding', 5);
      
      % A box in `newExpBox`, which will contain 2 boxes: 
      % 1) `expSelectBox`, which will contain subject, rig, exp
      % framework, and exp def dropdown menus, and 'start' and 'options'
      % buttons
      % 2) `obj.AlyxPanel`, an Alyx panel 
      headerBox = uix.HBox('Parent', newExpBox);
      expSelectBox = uix.VBox('Parent', headerBox);
      expSelectGrid = uiextras.Grid('Parent', expSelectBox);
      subjectLabel = bui.label('Subject', expSelectGrid);
      rigLabel = bui.label('Rig', expSelectGrid); 
      frameworkLabel = bui.label('Exp Framework', expSelectGrid); 
      expDefLabel = bui.label('Exp Def', expSelectGrid);
      
      % add 'Options' button
      obj.RigOptionsButton =...
        uicontrol('Parent', expSelectGrid,...
                  'Style', 'pushbutton',...
                  'String', 'Options',...
                  'TooltipString', 'Set services and delays',...
                  'Callback', @(~,~) obj.rigOptions(),...
                  'Enable', 'off');
              
      % subject dropdown menu and listener
      obj.NewExpSubjects =... 
        bui.Selector(expSelectGrid,... 
                     unique([{'default'}; dat.listSubjects])); 
%       set(subjectLabel, 'FontSize', 11); % Make 'Subject' label larger
%       set(obj.NewExpSubjects.UIControl, 'FontSize', 11); % Make dropdown box text larger
      obj.NewExpSubjects.addlistener('SelectionChanged',...
                                     @obj.expSubjectChanged);

      % rig dropdown menu and listeners                           
      obj.RemoteRigs = bui.Selector(expSelectGrid, srv.stimulusControllers); 
      obj.RemoteRigs.addlistener('SelectionChanged',...
                                 @(src,~) obj.remoteRigChanged); 
      obj.Listeners = arrayfun(@obj.listenToRig, obj.RemoteRigs.Option,...
                               'UniformOutput', false);
                                 
      % exp framework dropdown menu and listeners 
      obj.ExpFrameworks =... 
        bui.Selector(expSelectGrid, {obj.NewExpFactory.label});
      obj.ExpFrameworks.addlistener('SelectionChanged',...
                                    @(~,~) obj.expTypeChanged());
      
      % exp def dropdown menu and listeners
      listedExpDefs = what(fullfile(pick(dat.paths, 'expDefinitions')));
      fullExpDefPaths =...
          cellfun(@(x) fullfile(listedExpDefs.path, x), listedExpDefs.m,...
                  'UniformOutput', false);
      fullExpDefPaths{end + 1} = '<Other>';              
      obj.ExpDefs = bui.Selector(expSelectGrid, fullExpDefPaths); 
      obj.ExpDefs.addlistener('SelectionChanged',...
                              @(~,~) obj.expTypeChanged());

      % add 'Start' button                   
      obj.BeginExpButton =...
        uicontrol('Parent', expSelectGrid,...
                  'Style', 'pushbutton',...
                  'String', 'Start',...
                  'TooltipString', 'Start an experiment',...
                  'Callback', @(~,~) obj.beginExp(),...
                  'Enable', 'off');                           
      
      % Set column widths
      expSelectGrid.ColumnSizes = [100, 200];
      
      % Create the Alyx panel
      obj.AlyxPanel = eui.AlyxPanel(headerBox);
      addlistener(obj.NewExpSubjects, 'SelectionChanged',...
                  @(src, evt) obj.AlyxPanel.dispWaterReq(src, evt));
      
      % Create Param Editor
      paramBox =...
        uiextras.Panel('Parent', newExpBox, 'Title', 'Parameters',...
                       'Padding', 5);
      % vertical box to hold parameters                   
      obj.ParamPanel = uiextras.VBox('Parent', paramBox, 'Padding', 5);
      % horizontal box for choosing parameter sets
      hbox = uiextras.HBox('Parent', obj.ParamPanel);
      bui.label('Current set:', hbox);
      % Current parameter set label
      obj.ParamProfileLabel =...
          bui.label('none', hbox, 'FontWeight', 'bold');
      % Set horizontal width for conditional vs global parameters in px
      hbox.Sizes = [60 400];
      % hbox for saved parameter sets
      hbox = uiextras.HBox('Parent', obj.ParamPanel, 'Spacing', 2);
      bui.label('Saved sets:', hbox);  % Add 'Saved sets' label
      obj.ParamProfiles = bui.Selector(hbox, {'none'}); % Make parameter sets dropdown box with default 'none' entry
      % 'Load' parameters set button: pass selected parameter set to
      % `loadParamProfile()` when pressed
      uicontrol('Parent', hbox,... 
        'Style', 'pushbutton',...
        'String', 'Load',...
        'Callback',...
        @(~,~) obj.loadParamProfile(obj.ParamProfiles.Selected));
      % 'Save' parameters set button
      uicontrol('Parent', hbox,... 
        'Style', 'pushbutton',...
        'String', 'Save',...
        'Callback', @(~,~) obj.saveParamProfile());
      % 'Delete' parameters set button
      uicontrol('Parent', hbox,... 
        'Style', 'pushbutton',...
        'String', 'Delete',...
        'Callback', @(~,~) obj.delParamProfile());
      % Set column widths for dropdown menu and buttons
      hbox.Sizes = [60 200 60 60 60];
      % Set vertical size for 'Current set' and 'Saved sets'
      obj.ParamPanel.Sizes = [25 25];
      % Set header box to take up 120 px, and rest taken up by ParamPanel
      newExpBox.Sizes = [120 -1];
      
      % a box on the 'Experiments' - 'Current' tab for showing info on
      % current experiments
      runningExpBox = uiextras.VBox('Parent', obj.ExpTabs, 'Padding', 5);
      obj.ActiveExpsGrid =...
        uiextras.Grid('Parent', runningExpBox, 'Spacing', 5);
      
      % 'Log' tab, which will contain 'Entries' and 'Weight' subject tabs
      logbox = uiextras.VBox('Parent', obj.TabPanel, 'Padding', 5);
      
      % create box for selecting Subject and holding plots in 'Log' tab
      hbox = uiextras.HBox('Parent', logbox, 'Padding', 5);
      bui.label('Subject', hbox);
      % subject dropdown menu & listener
      obj.LogSubjects =...
        bui.Selector(hbox, unique([{'default'}; dat.listSubjects]));
      addlistener(obj.LogSubjects, 'SelectionChanged',...
          @(src, evt) obj.AlyxPanel.dispWaterReq(src, evt));
      % resize label and dropdown to be 50px and 100px respectively
      hbox.Sizes = [50 100];
      % Log tabs, which will contain the 'Entries' and 'Weights' tabs
      obj.LogTabs = uiextras.TabPanel('Parent', logbox, 'Padding', 5);
      % 'Entries' window as `eui.Log` object
      obj.Log = eui.Log(obj.LogTabs); 
      obj.LogSubjects.addlistener('SelectionChanged',...
        @(~, ~) obj.LogSubjectsChanged());
      % Make the 'Entries' tab take up 34 px in width 
      logbox.Sizes = [34 -1];

      % weight tab
      weightBox = uiextras.VBox('Parent', obj.LogTabs, 'Padding', 5);
      % Mouse weight plot axes
      obj.WeightAxes = bui.Axes(weightBox); 
      obj.WeightAxes.NextPlot = 'add';
      % box below `WeightAxes` for 'Tare' and 'Record' buttons
      hbox = uiextras.HBox('Parent', weightBox, 'Padding', 5); 
      % empty space for padding (to right-align buttons)
      uiextras.Empty('Parent', hbox);
      % Tare button
      uicontrol('Parent', hbox, 'Style', 'pushbutton',...
        'String', 'Tare scales',...
        'TooltipString', 'Tare the scales',...
        'Callback', @(~,~) obj.WeighingScale.tare(),...
        'Enable', 'on');
      % Record button
      obj.RecordWeightButton =...
        uicontrol('Parent', hbox, 'Style', 'pushbutton',...
        'String', 'Record',...
        'TooltipString', 'Record the current weight reading (star symbol)',...
        'Callback', @(~,~) obj.recordWeight(),...
        'Enable', 'off');
      % resize buttons to be 80 and 100px respectively
      hbox.Sizes = [-1 80 100];
      % make hbox size 36px high
      weightBox.Sizes = [-1 36];
      
      % setup the tab names/sizes
      obj.TabPanel.TabSize = 80;
      obj.TabPanel.TabNames = {'Experiments', 'Log'};
      obj.TabPanel.SelectedChild = 1;
      obj.ExpTabs.TabNames = {'New', 'Current'};
      obj.ExpTabs.SelectedChild = 1;
      obj.LogTabs.TabNames = {'Entries' 'Weight'};
      obj.TabPanel.SelectionChangedFcn = @(~,~)obj.tabChanged;
    end
    
    function delete(obj)
      disp('MControl destructor called');
      obj.cleanup();
      if obj.RootContainer.isvalid
        delete(obj.RootContainer);
      end
    end
  
    function newScalesReading(obj, ~, ~)
      if obj.TabPanel.SelectedChild == 1 && obj.LogTabs.SelectedChild == 2
        obj.plotWeightReading(); %refresh weighing scale reading
      end
    end
    
    function tabChanged(obj)
    % Function to change which subject Alyx uses when user changes tab
      if ~obj.AlyxPanel.AlyxInstance.IsLoggedIn; return; end
      if obj.TabPanel.SelectedChild == 1 % Log tab
        obj.AlyxPanel.dispWaterReq(obj.LogSubjects);
      else % SelectedChild == 2 Experiment tab
        obj.AlyxPanel.dispWaterReq(obj.NewExpSubjects);
      end
    end
    
    function expSubjectChanged(obj, ~, src)
        % callback for when subject is changed
        switch src.EventName
            case 'SelectionChanged' % user selected a new subject
                % 'refresh' experiment type - this method allows the relevent parameters to be loaded for the new subject
                obj.expTypeChanged(); 
            case 'Connected' % user logged in to Alyx
                % Change subject list to database list
                obj.NewExpSubjects.Option = obj.AlyxPanel.SubjectList;
                obj.LogSubjects.Option = obj.AlyxPanel.SubjectList;
                % if selected is not in the database list, switch to
                % default
                if ~any(strcmp(obj.NewExpSubjects.Selected, obj.AlyxPanel.SubjectList))
                    obj.NewExpSubjects.Selected = 'default';
                    obj.expTypeChanged();
                end
                if ~any(strcmp(obj.LogSubjects.Selected, obj.AlyxPanel.SubjectList))
                    obj.LogSubjects.Selected = 'default';
                    obj.expTypeChanged();
                end
                obj.AlyxPanel.dispWaterReq(obj.NewExpSubjects);
            case 'Disconnected' % user logged out of Alyx
                obj.NewExpSubjects.Option = unique([{'default'}; dat.listSubjects]);
                obj.LogSubjects.Option = unique([{'default'}; dat.listSubjects]);
        end
    end
    
    function expTypeChanged(obj)
      % callback for when experiment framework or exp def is changed
      
      type = obj.ExpFrameworks.Selected;
      
      % if the selected exp def is '<Other>', choose it from the file
      % explorer
      if strcmpi(obj.ExpDefs.Selected, '<Other>')
        defdir = fullfile(pick(dat.paths, 'expDefinitions'));
        [mfile, fpath] = uigetfile(...
          '*.m', 'Select the experiment definition function', defdir);
        if ~mfile
          return
        end
      end
      
      % set parameters based on selected framework
      switch type
        case 'signals'
          idx = strcmp({obj.NewExpFactory.label},'signals');
          obj.NewExpFactory(idx).defaultParamsFun = ...
            @()exp.inferParameters(fullfile(fpath, mfile)); % change default paramters function handle to infer params for this specific expDef
          obj.NewExpFactory(idx).matchTypes{end+1} = fullfile(fpath, mfile); % add specific expDef to NewExpFactory
      end
      
      % special cases for default parameter profiles and 'default' subject
      defaultProfiles = {'<last for subject>'; '<default set>'};
      savedProfiles = fieldnames(dat.loadParamProfiles(type));
      obj.ParamProfiles.Option = [defaultProfiles; savedProfiles];
      str = iff(strcmp('default', obj.NewExpSubjects.Selected),... % && ~strcmp(obj.ExpDefs.Selected, '<custom...>'),
              '<default set>', '<last for subject>');
      obj.loadParamProfile(str);
    end
    
    function delParamProfile(obj) % Called when 'Delete...' button is pressed next to saved sets
      profile = obj.ParamProfiles.Selected; % Get param profile that was selected from the dropdown?
      assert(profile(1) ~= '<', 'Special case profile %s cannot be deleted', profile); % If '<last for subject>' or '<defaults>' is selected give error
      q = sprintf('Are you sure you want to delete parameters profile ''%s''', profile);
      doDelete = strcmp(questdlg(q, 'Delete', 'Yes', 'No', 'No'),  'Yes'); % Find out whether they confirmed delete
      if doDelete % They pressed 'Yes'
        if strcmp(obj.ExpDefs.Selected, '<custom...>') % Was it a signals parameter?
          type = 'custom';
        else
          type = obj.ExpDefs.Selected;
        end
        dat.delParamProfile(type, profile); 
        %remove the profile from the control options
        profiles = obj.ParamProfiles.Option; % Get parameter profile
        obj.ParamProfiles.Option = profiles(~strcmp(profiles, profile)); % Set new list without deleted profile
        %log the parameters as being deleted
        obj.log('Deleted parameter set ''%s''', profile);
      end
    end
    
    function saveParamProfile(obj) % Called by 'Save...' button press, save a new parameter profile
      selProfile = obj.ParamProfiles.Selected; % Find which set is currently selected
      % This statement is for autofilling the save as input dialog; default
      % value is currently selected profile name, however if a special case
      % profile is selected there is no default value
      def = iff(selProfile(1) ~= '<', selProfile, '');
      ipt = inputdlg('Enter a name for the parameters profile', 'Name', 1, {def});
      if isempty(ipt)
        return
      else
        name = ipt{1}; % Get the name they entered into the dialog
      end
      doSave = true;
      validName = matlab.lang.makeValidName(name); % 2017-02-13 MW changed from genvarname for future compatibility
      if ~strcmp(name, validName) % If the name they entered is non-alphanumeric...
        q = sprintf('''%s'' is not valid (names must be alphanumeric with no spaces)\n', name);
        q = [q sprintf('Do you want to use ''%s'' instead?', validName)];
        doSave = strcmp(questdlg(q, 'Name', 'Yes', 'No', 'No'),  'Yes'); % Do they still want to save with suggested name?
      end
      if doSave % Going ahead with save
        if strcmp(obj.ExpDefs.Selected, '<custom...>') % Is parameter set for signals?
          type = 'custom';
        else
          type = obj.ExpDefs.Selected; % Which world is this set for?
        end
        dat.saveParamProfile(type, validName, obj.Parameters.Struct); % Save
        %add the profile to the control options
        profiles = obj.ParamProfiles.Option;
        if ~any(strcmp(obj.ParamProfiles.Option, validName))
          obj.ParamProfiles.Option = [profiles; validName];
        end
        obj.ParamProfiles.Selected = validName;
        %set label for loaded profile
        set(obj.ParamProfileLabel, 'String', validName, 'ForegroundColor', [0 0 0]);
        obj.log('Saved parameters as ''%s''', validName);
      end
    end
    
    function loadParamProfile(obj, profile)
      set(obj.ParamProfileLabel, 'String', 'loading...', 'ForegroundColor', [1 0 0]); % Red 'Loading...' while new set loads
      if ~isempty(obj.ParamEditor)
        % Clear existing parameters control
        clear(obj.ParamEditor)
      end
      
      factory = obj.NewExpFactory; % Find which 'world' we are in
      typeName = obj.ExpDefs.Selected; 
      if strcmp(typeName, '<custom...>')
        typeNameFinal = 'custom';
      else
        typeNameFinal = typeName;
      end
      matchTypes = factory(strcmp({factory.label}, typeName)).matchTypes();
      subject = obj.NewExpSubjects.Selected; % Find which subject is selected
      label = 'none';
      set(obj.BeginExpButton, 'Enable', 'off') % Can't run experiment without params!
      switch lower(profile)
        case '<defaults>'
          %           if strcmp(obj.ExpDefs.Selected, '<custom...>')
          %             paramStruct = factory(strcmp({factory.label}, typeName)).defaultParamsFun();
          %             label = 'inferred';
          %           else
          paramStruct = factory(strcmp({factory.label}, typeName)).defaultParamsFun();
          label = 'defaults';
          %           end
        case '<last for subject>'
          %% find the most recent experiment with parameters of selected type
          % list of all subject's experiments, with most recent first
          refs = flipud(dat.listExps(subject));
          % function takes parameters and returns true if of selected type
          if any(strcmp(matchTypes, 'custom')) % If custom, find last parameter set for specific expDef
            matching = @(pars) iff(isfield(pars, 'defFunction'),...
                @()any(strcmpi(pick(pars, 'defFunction'), matchTypes)), false);
          else
            matching = @(pars) any(strcmp(pick(pars, 'type', 'def', ''), matchTypes));
          end
          % create a sequence of the parameters of each experiment
          paramsSeq = sequence(refs, @dat.expParams);
          % get the first (most recent) parameters whose type matches
          [paramStruct, ref] = paramsSeq.filter(matching).first;
          if ~isempty(paramStruct) % found one
            paramStruct.type = typeNameFinal; % override type name with preferred
            label = sprintf('from last experiment of %s (%s)', subject, ref);
          end
        otherwise
          label = profile;
          saved = dat.loadParamProfiles(typeNameFinal);
          paramStruct = saved.(profile);
          paramStruct.type = typeNameFinal; % override type name with preferred
      end
      set(obj.ParamProfileLabel, 'String', label, 'ForegroundColor', [0 0 0]);
      if isfield(paramStruct, 'services')
        %remove the services field since this application will specifically
        %set that field
        paramStruct = rmfield(paramStruct, 'services');
      end
      obj.Parameters.Struct = paramStruct;
      if isempty(paramStruct); return; end
      % Now parameters are loaded, pass to ParamEditor for display, etc.
      if isempty(obj.ParamEditor)
        obj.ParamEditor = eui.ParamEditor(obj.Parameters, obj.ParamPanel); % Build parameter list in Global panel by calling eui.ParamEditor
      else
        obj.ParamEditor.buildUI(obj.Parameters);
      end
      obj.ParamEditor.addlistener('Changed', @(src,~) obj.paramChanged);
      if strcmp(obj.RemoteRigs.Selected.Status, 'idle')
        set(obj.BeginExpButton, 'Enable', 'on') % Re-enable start button
      end
    end
    
    function paramChanged(obj)
      % PARAMCHANGED Indicate to user that parameters have been updated
      %  Changes the label above the ParamEditor indicating that the
      %  parameters have been edited
      s = get(obj.ParamProfileLabel, 'String');
      if ~strEndsWith(s, '[EDITED]')
        set(obj.ParamProfileLabel, 'String', [s ' ' '[EDITED]'], 'ForegroundColor', [1 0 0]);
      end
    end
    
    function l = listenToRig(obj, rig)
      l = [event.listener(rig, 'Connected', @obj.rigConnected)...
        event.listener(rig, 'Disconnected', @obj.rigDisconnected)...
        event.listener(rig, 'ExpStopped', @obj.rigExpStopped)...
        event.listener(rig, 'ExpStarted', @obj.rigExpStarted)];
    end
    
    function rigExpStarted(obj, rig, evt) % Announce that the experiment has started in the log box
        obj.log('''%s'' on ''%s'' started', evt.Ref, rig.Name);
    end
    
    function rigExpStopped(obj, rig, evt) % Announce that the experiment has stopped in the log box
      obj.log('''%s'' on ''%s'' stopped', evt.Ref, rig.Name);
      if rig == obj.RemoteRigs.Selected
        set(obj.RigOptionsButton, 'Enable', 'on'); % Enable 'Options'
      end
      if obj.Parameters.Struct~=nil % If params loaded
        set(obj.BeginExpButton, 'Enable', 'on'); % Re-enable 'Start' button so a new experiment can be started on that rig
      end
      % Alyx water reporting: indicate amount of water this mouse still needs     
      if rig.AlyxInstance.IsLoggedIn
          try
              subject = dat.parseExpRef(evt.Ref);
              sd = rig.AlyxInstance.getData(sprintf('subjects/%s', subject));
              obj.log('Water requirement remaining for %s: %.2f (%.2f already given)', ...
                  subject, sd.remaining_water, ...
                  sd.expected_water-sd.remaining_water);
          catch
              subject = dat.parseExpRef(evt.Ref);
              obj.log('Warning: unable to query Alyx about %s''s water requirements', subject);
          end
          % Remove AlyxInstance from rig; no longer required
%           delete(rig.AlyxInstance); % Line invalid now Alyx no longer
%           handel class
          rig.AlyxInstance = [];
      end
    end
    
    function rigConnected(obj, rig, ~)
      % RIGDCONNECTED Callback when notified of the rig object's 'Connected' event
      %   Called when the rig object status is changed to 'connected', i.e.
      %   when the mc computer has successfully connected to the remote
      %   rig.  Enables the 'Start' and 'Rig optoins' buttons and logs the
      %   event in the Logging Display Now that the rig is connected, this
      %   function queries the status of the remote rig.  If the remote rig
      %   is running an experiment, it returns the expRef for the
      %   experiment that is running.  In this case a dialog is spawned
      %   notifying the user.  The user can either do nothing or choose to
      %   view the active experiment, in which case a new EXPPANEL is
      %   created
      %
      % See also REMOTERIGCHANGED, SRV.STIMULUSCONTROL, EUI.EXPPANEL
        
      % If rig is connected check no experiments are running...
      expRef = rig.ExpRunning; % returns expRef if running
      if expRef
          choice = questdlg(['Attention: An experiment is already running on ', rig.Name], ...
              upper(rig.Name), 'View', 'Cancel', 'Cancel');
          switch choice
              case 'View'
                  % Load the parameters from file
                  paramsPath = dat.expFilePath(expRef, 'parameters', 'master');
                  paramStruct = load(paramsPath);
                  if ~isfield(paramStruct.parameters, 'type')
                      paramStruct.type = 'custom'; % override type name with preferred
                  end
                  % Determine the experiment start time
                  try % Try getting data from Alyx
                    ai = obj.AlyxPanel.AlyxInstance;
                    assert(ai.IsLoggedIn)
                    meta = ai.getSessions(expRef);
                    startedTime = ai.datenum(meta.start_time);
                  catch % Fall back on parameter file's system mod date
                    startedTime = file.modDate(paramsPath);
                  end
                  % Instantiate an ExpPanel and pass it the expRef and parameters
                  panel = eui.ExpPanel.live(obj.ActiveExpsGrid, expRef, rig,...
                    paramStruct.parameters, 'StartedTime', startedTime);
                  obj.LastExpPanel = panel;
                  % Add a listener for the new panel
                  panel.Listeners = [panel.Listeners
                      event.listener(obj, 'Refresh', @(~,~)panel.update())];
                  obj.ExpTabs.SelectedChild = 2; % switch to the active exps tab
              case 'Cancel'
                  return
          end
      else % The rig is idle...
        obj.log('Connected to ''%s''', rig.Name); % ...say so in the log box
        if rig == obj.RemoteRigs.Selected
          set(obj.RigOptionsButton, 'Enable', 'on'); % Enable 'Options' button
        end
        if obj.Parameters.Struct~=nil % If parameters loaded
          set(obj.BeginExpButton, 'Enable', 'on');
        end
      end
    end
    
    function rigDisconnected(obj, rig, ~)
      % RIGDISCONNECTED Callback when notified of the rig object's 'Disconnected' event
      %   Called when the rig object status is changed to 'disconnected',
      %   i.e. when the rig is no longer connected to the mc computer.
      %   Disables the 'Start' and 'Rig optoins' buttons and logs the event
      %   in the Logging Display
      %
      % See also REMOTERIGCHANGED, SRV.STIMULUSCONTROL
      %
      % If rig is disconnected...
      obj.log('Disconnected from ''%s''', rig.Name); % ...say so in the log box
      if rig == obj.RemoteRigs.Selected 
        set([obj.BeginExpButton obj.RigOptionsButton], 'Enable', 'off'); % Grey out 'Start' button
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
    
    function remoteRigChanged(obj)
      set(obj.RigOptionsButton, 'Enable', 'off');
      rig = obj.RemoteRigs.Selected;
      if ~isempty(rig) && strcmp(rig.Status, 'disconnected')
        %attempt to connect to rig
        try
          rig.connect(); % srv.StimulusControl/connect
        catch ex
          errmsg = ex.message;
          croplen = 200;
          if length(errmsg) > croplen
            %crop overly long messages
            errmsg = [errmsg(1:croplen) '...'];
          end
          obj.log('Could not connect to ''%s'' (%s)', rig.Name, errmsg);
        end
      elseif strcmp(rig.Status, 'idle')
        set(obj.RigOptionsButton, 'Enable', 'on');
        if obj.Parameters.Struct~=nil
          set(obj.BeginExpButton, 'Enable', 'on');
        end
      else
        obj.rigConnected(rig);
      end
    end
    
    function rigOptions(obj)
        % RIGOPTIONS A callback for the 'Rig Options' button
        %   Opens a dialog allowing one to select which of the selected
        %   rig's services to start during experiment initialization, and
        %   to set any pre- and post-experiment delays.
        %
        %   See also SRV.STIMULUSCONTROL
        rig = obj.RemoteRigs.Selected; % Find which rig is selected
        % Create a dialog to display the selected rig options
        d = dialog('Position',[300 300 150 150],'Name', [upper(rig.Name) ' options']);
        vbox = uix.VBox('Parent', d, 'Padding', 5);
        bui.label('Services:', vbox); % Add 'Services' label
        c = gobjects(1, length(rig.Services));
        % Ensure that SelectedServices is the correct size
        if length(rig.SelectedServices)~=length(rig.Services)
          rig.SelectedServices = true(size(rig.Services));
        end
        if numel(rig.Services) % If the rig has any services...
          for i = 1:length(rig.Services) % ...create a check box for each of them
            c(i) = uicontrol('Parent', vbox, 'Style', 'checkbox',...
                'String', rig.Services{i}, 'Value', rig.SelectedServices(i));
          end
        else % Otherwise indicate that no services are availible
          bui.label('No services available', vbox);
          i = 1; % The number of services+1, used to set the container heights
        end
        uix.Empty('Parent', vbox);
        bui.label('Delays:', vbox); % Add 'Delyas' label next to rig dropdown
        preDelaysBox = uix.HBox('Parent', vbox);
        bui.label('Pre', preDelaysBox);
        pre = uicontrol('Parent', preDelaysBox,... % Add 'Pre' textbox
            'Style', 'edit',...
            'BackgroundColor', [1 1 1],...
            'HorizontalAlignment', 'left',...
            'Enable', 'on',...
            'Callback', @(src, evt) put(obj.RemoteRigs.Selected,... % SetField 'ExpPreDelay' in obj.RemoteRigs.Selected to what ever was enetered
            'ExpPreDelay', str2double(get(src, 'String'))));
        postDelaysBox = uix.HBox('Parent', vbox);
        bui.label('Post', postDelaysBox); % Add 'Post' label
        post = uicontrol('Parent', postDelaysBox,... % Add 'Post' textbox
            'Style', 'edit',...
            'BackgroundColor', [1 1 1],...
            'HorizontalAlignment', 'left',...
            'Enable', 'on',...
            'Callback', @(src, evt) put(obj.RemoteRigs.Selected,...  % SetField 'ExpPostDelay' in obj.RemoteRigs.Selected to what ever was enetered
            'ExpPostDelay', str2double(get(src, 'String'))));
        obj.PrePostExpDelayEdits = [pre post]; % Store Pre and Post values in obj
        uix.Empty('Parent', vbox);
        uicontrol('Parent',vbox,...
            'Position',[89 20 70 25],...
            'String','Okay',...
            'Callback',@rigOptions_callback);
        vbox.Heights = [20 repmat(15,1,i) -1 15 15 15 15 20];
        set(obj.PrePostExpDelayEdits(1), 'String', num2str(rig.ExpPreDelay));
        set(obj.PrePostExpDelayEdits(2), 'String', num2str(rig.ExpPostDelay));
        function rigOptions_callback(varargin)
            % RIGOPTIONS_CALLBACK A callback for the rig options 'Okay'
            %   button.  Here we process the state of each services
            %   check-box and set the selected services accordingly
            %
            %   See also SRV.STIMULUSCONTROL
            vals = get(c,'Value');
            if iscell(vals); vals = cell2mat(vals); end
            rig.SelectedServices = logical(vals');
            close(gcf) % close the 
        end
    end
        
    function beginExp(obj)
        % BEGINEXP The callback for the 'Start' button
        %   Disables the start buttons, commands the remote rig to being an
        %   experiment and calls the EXPPANEL object for monitoring the
        %   experiment.  Additionally if the user is not logged into Alyx
        %   (i.e. no Alyx token is set), the user is prompted to log in and
        %   the token is stored in the rig object so that EXPPANEL can
        %   later post any events to Alyx (for example the amount of water
        %   received during the task).  An Alyx Experiment and, if required, Base
        %   session are also created here.
        % 
        % See also SRV.STIMULUSCONTROL, EUI.EXPPANEL, EUI.ALYXPANEL
        set([obj.BeginExpButton obj.RigOptionsButton], 'Enable', 'off'); % Grey out buttons
        rig = obj.RemoteRigs.Selected; % Find which rig is selected
        if strcmpi(rig.Status, 'running') 
            obj.log('Failed because another experiment is running');
            return;
        end
        % Save the current instance of Alyx so that eui.ExpPanel can register water to the correct account
        if ~obj.AlyxPanel.AlyxInstance.IsLoggedIn &&...
            ~strcmp(obj.NewExpSubjects.Selected,'default') &&...
            ~obj.AlyxPanel.AlyxInstance.Headless
          try
            obj.AlyxPanel.login();
            assert(obj.AlyxPanel.AlyxInstance.IsLoggedIn||obj.AlyxPanel.AlyxInstance.Headless);
          catch
            obj.log('Warning: Must be logged in to Alyx before running an experiment')
            return
          end
        end
        % Find which services should be started by expServer
        services = rig.Services(rig.SelectedServices);
        % Add these services to the parameters
        obj.Parameters.set('services', services(:),...
            'List of experiment services to use during the experiment');
        % Create new experiment reference
        [expRef, ~, url] = obj.AlyxPanel.AlyxInstance.newExp(...
          obj.NewExpSubjects.Selected, now, obj.Parameters.Struct); 
        % Add a copy of the AlyxInstance to the rig object for later
        % water registration, &c.
        rig.AlyxInstance = obj.AlyxPanel.AlyxInstance;
        rig.AlyxInstance.SessionURL = url;
        
        panel = eui.ExpPanel.live(obj.ActiveExpsGrid, expRef, rig, obj.Parameters.Struct);
        obj.LastExpPanel = panel;
        panel.Listeners = [panel.Listeners
            event.listener(obj, 'Refresh', @(~,~)panel.update())];
        obj.ExpTabs.SelectedChild = 2; % switch to the active exps tab
        rig.startExperiment(expRef); % Tell rig to start experiment
        %update the parameter set label to indicate used for this experiment
        subject = dat.parseExpRef(expRef);
        parLabel = sprintf('from last experiment of %s (%s)', subject, expRef);
        set(obj.ParamProfileLabel, 'String', parLabel, 'ForegroundColor', [0 0 0]);
    end
    
    function updateWeightPlot(obj)
      entries = obj.Log.entriesByType('weight-grams');
      datenums = floor([entries.date]);
      obj.WeightAxes.clear();
      if obj.AlyxPanel.AlyxInstance.IsLoggedIn && ~strcmp(obj.LogSubjects.Selected,'default')
        obj.AlyxPanel.viewSubjectHistory(obj.WeightAxes.Handle)
        rotateticklabel(obj.WeightAxes.Handle, 45);
      else
        if numel(datenums) > 0
          obj.WeightAxes.plot(datenums, [entries.value], '-o');
          dateticks = min(datenums):floor(now);
          set(obj.WeightAxes.Handle, 'XTick', dateticks);
          obj.WeightAxes.XTickLabel = datestr(dateticks, 'dd-mm');
          obj.WeightAxes.yLabel('Weight (g)');
          xl = [min(datenums) floor(now)];
          if diff(xl) <= 0
            xl(1) = xl(2) - 0.5;
            xl(2) = xl(2) + 0.5;
          end
          obj.WeightAxes.XLim = xl;
          rotateticklabel(obj.WeightAxes.Handle, 45);
        end
      end
    end
    
    function plotWeightReading(obj)
      %plots the current reading if any from the scales
      if ishandle(obj.WeightReadingPlot)
        set(obj.RecordWeightButton, 'Enable', 'off', 'String', 'Record');
        delete(obj.WeightReadingPlot);
        obj.WeightReadingPlot = [];
      end
      if ~isempty(obj.WeighingScale)
        %scales are attached and initialised so take a reading
        g = obj.WeighingScale.readGrams;
        MinSignificantWeight = 5; %grams
        if g >= MinSignificantWeight
          obj.WeightReadingPlot = obj.WeightAxes.scatter(floor(now), g, 20^2, 'p', 'filled');
          obj.WeightAxes.XLim = [min(get(obj.WeightAxes.Handle, 'XTick')) max(now)];
          set(obj.RecordWeightButton, 'Enable', 'on', 'String', sprintf('Record %.1fg', g));
        end
      end
    end
    
    function cleanup(obj)
      % delete the rig listeners
      cellfun(@delete, obj.Listeners);
      obj.Listeners = {};
      if ~isempty(obj.RefreshTimer)
        stop(obj.RefreshTimer);
        delete(obj.RefreshTimer);
        obj.RefreshTimer = [];
      end
      % delete the AlyxPanel object
      if ~isempty(obj.AlyxPanel); delete(obj.AlyxPanel); end
      %close connectiong to weighing scales
      if ~isempty(obj.WeighingScale)
        obj.WeighingScale.cleanup();
      end
      % disconnect all connected rigs
      arrayfun(@(r) r.disconnect(), obj.RemoteRigs.Option);
    end
    
    function LogSubjectsChanged(obj)
      obj.Log.setSubject(obj.LogSubjects.Selected);
      obj.updateWeightPlot();
    end
    
    function recordWeight(obj)
      subject = obj.LogSubjects.Selected;
      grams = get(obj.WeightReadingPlot, 'YData');
      dat.addLogEntry(subject, now, 'weight-grams', grams, '');            
      
      obj.log('Logged weight of %.1fg for ''%s''', grams, subject);
      % post weight to Alyx
      obj.AlyxPanel.recordWeight(grams, subject)
      
      %refresh log entries so new weight reading is plotted
      obj.Log.setSubject(obj.LogSubjects.Selected);
      obj.updateWeightPlot();
    end

  end
  
end
classdef SerialDevice < handle
    % SerialDevice facilitates communications with a serial-port attached device
    %  Implements the following 'device' paradigm
    %   - Connected to a serialport.
    %   - Only one transaction can be sent to the device at any given time
    %   - Supports directives:
    %       - 'connect'/'disconnect'
    %       - 'BaudRate':   gets or sets the port's speed
    %       - 'quit':       tells the worker process to die
    %   - Supports atomic sending one or more commands to the device and
    %       getting the respective responses (optionally: no response, e.g. 'reset')
    %   - A 'status' command is periodically issued to the device.
    %
    %   - Uses a parallel process (worker) that actually talks to the
    %      device, thus isolating the handling of the serialport.
        
    properties
        Connected   logical = false
        Logging     logical = false
    end

    properties(Hidden=true)      
        Job             % [Job]         the Job that runs the worker
        Task
        Store
        WorkerArgs
        WorkerException        
        ExceptionId string = "OCS:SerialDevice";
        PortPath
        WorkerCheckingTimer timer
        ComponentsName string
        PortConditioner function_handle

        Monitoring  logical = false
        Status
        BaudRate    double
        Locked      logical = false
        Logger

        CommandResponseIsAvailable   logical    % set by onValueStoreUpdate for 'command-response'
        DirectiveResponseIsAvailable logical    % set by onValueStoreUpdate for 'directive-response'
    end

    properties(Constant=true,Hidden=true)
        DirectiveKey         string = 'directive';
        DirectiveResponseKey string = 'directive-response';
        CommandKey           string = 'command';
        CommandResponseKey   string = 'command-response';
        ExceptionKey         string = 'exception';
        StatusKey            string = 'status';
    end

    
    methods

        %
        % Constructor.  Gathers the arguments for the SerialWorker
        %
        function Obj = SerialDevice(PortPath, Args)
            arguments
                PortPath                    string;
                Args.PortSpeed              double = 115200;        % baud rate
                Args.Timeout                duration;               % duration to wait for a response
                Args.Terminator             string;                 % same as per serialport
                Args.InterStatus            duration;               % interval between status reads
                Args.ResponseTime           duration;               % to wait between sending something and getting a response
                Args.StatusCommand          inst.SerialCommand;     % SerialCommand(s) for getting status from device
                Args.Validator              function_handle;	    % checks if the device's response is valid, throws exception if not
                Args.Reader                 function_handle;        % user-specified serial device reader
                Args.Writer                 function_handle;        % user-specified serial device writer
                Args.InterCommand           duration;               % delay between sending a series of commands
                Args.ConnectRetries         double;                 % how many times to try to open the serialport (may be Inf)
                Args.ConnectRetryDelay      duration;               % delay between connect retries
                Args.EndOfLoopDelay         duration;               % delay at the end of the loop in the worker
                Args.PortConditioner        function_handle;        % called on serial error, to set reasonable values
                Args.Logging                logical;                % do/don't log
            end
                        
            if isMATLABReleaseOlderThan("R2022a")
                throw(MException("OCS:SerialDevice:MatlabRelease", "This class works on release R2022a or newer (current release: %s)", matlabRelease.Release))
            end

            Logdir = '/var/log/ocs';
            [~,~,~] = mkdir(Logdir);
            Obj.Logger = MsgLogger(...
                'FileName',     sprintf('%s/SerialDevice-%s.txt', Logdir, replace(PortPath, '/', '_')), ...
                'LoadConfig',   false, ...
                'Console',      false);

            if isempty(PortPath)
                throw(MException(Obj.ExceptionId,'Empty PortPath argument'));
            end

            knownports = serialportlist;
            if isempty(knownports)
                throw(MException(Obj.ExceptionId,'No serial ports on this machine'));
            end

            if ~ismember(PortPath, knownports)
                throw(MException(Obj.ExceptionId, sprintf("Unknown port '%s' (known ports: %s)", PortPath, strjoin(knownports, ", "))));
            end

            if numel(Args.StatusCommand) > 1
                Obj.Monitoring = true;
                Args.Mononitoring = true;
            end

            if isfield(Args, 'PortConditioner')
                Obj.PortConditioner = Args.PortConditioner;
            end

            Obj.PortPath = PortPath;
            Obj.WorkerArgs = Args;
            Obj.WorkerArgs.PortPath = PortPath;
            Obj.Connected = false;
        end

        function tf = get.Connected(Obj)
            tf = Obj.Connected;
        end

        function set.Connected(Obj, Value)
            Obj.Connected = Value;
        end

        function tf = get.Locked(Obj)
            tf = Obj.directive('locked');
        end

        function set.Locked(Obj, Value)
            Obj.Locked = Obj.directive('locked', Value);
        end

        function tf = get.Monitoring(Obj)
            if Obj.Connected
                tf = Obj.directive('monitoring');
            else
                tf = Obj.Monitoring;
            end
        end

        function set.Monitoring(Obj, Value)
            Obj.Monitoring = Value;
            if Obj.Monitoring && Obj.Connected
                Obj.directive('monitoring', Value)
            end
        end

        function rate = get.BaudRate(Obj)
            rate = Obj.directive('BaudRate');
        end

        function set.BaudRate(Obj, Value)
            Obj.directive('BaudRate', Value);
        end

        %
        % Actually tells the worker to connect to the device
        %
        function connect(Obj)
            db = dbstack(); Func = string([db(1).name ': ']);

            Obj.ComponentsName = sprintf("SerialWorker-%s", replace(Obj.WorkerArgs.PortPath, '/', '_'));

            delete(timerfind('Name', Obj.ComponentsName))
            delete(findJob(parcluster, 'Name', Obj.ComponentsName))

            Obj.Job = createJob(parcluster);
            Obj.Job.Name = Obj.ComponentsName;
            Obj.Task = createTask(Obj.Job, @makeSerialWorker, 0, {Obj.WorkerArgs});

            Obj.Job.AutoAddClientPath = true;
            submit(Obj.Job);
            Obj.log(" ");
            Obj.log(Func + "submitted job%d", Obj.Job.ID);
            while ~strcmp(Obj.Job.State, 'running')
                pause(.1);
            end
            Obj.log(Func + "job%d is running", Obj.Job.ID);
            Obj.Store = Obj.Job.ValueStore;
            Obj.Store.KeyUpdatedFcn = @Obj.onValueStoreUpdate;

            Obj.WorkerCheckingTimer = timer();
            Obj.WorkerCheckingTimer.TimerFcn = @(~,~)onTimer(Obj);
            Obj.WorkerCheckingTimer.Name = Obj.ComponentsName;
            Obj.WorkerCheckingTimer.ExecutionMode = 'fixedRate';
            Obj.WorkerCheckingTimer.BusyMode = 'queue';
            Obj.WorkerCheckingTimer.Period = 5;
            start(Obj.WorkerCheckingTimer)

            Obj.log(Func + "sending connected=true");
            response = Obj.directive('connected', true);
            if isa(response, 'MException')
                throwAsCaller(response);
            elseif isa(response, 'logical')
                Obj.Connected = response;
            end

            if ~isempty(Obj.PortConditioner)
                Obj.log(Func + sprintf("conditioning '%s'", Obj.PortPath));
                Obj.PortConditioner(Obj);
            end
            
            Obj.log(Func + "connected: %s", string(Obj.Connected));
        end
        
        %
        % 1. Tells the worker to disconnect from the device
        % 2. Waits for the worker to finish disconnecting
        % 3. Destroys the worker
        %
        function Obj = disconnect(Obj)
            db = dbstack(); Func = string([db(1).name ': ']);

            Response = [];
            if Obj.Connected && ~isempty(Obj.Job) && isvalid(Obj.Job)
                Obj.log(Func + "sending 'connected=false'");
                try
                    Response = Obj.directive("connected", false);
                catch ME
                    throwAsCaller(ME)
                end
            end
            if ~isempty(Obj.Job) && isvalid(Obj.Job)
                cancel(Obj.Job);
            end
            delete(Obj.Job);
            stop(Obj.WorkerCheckingTimer);
            delete(Obj.WorkerCheckingTimer)
            Obj.Connected = false;
            Obj.Job = [];
            Obj.Store = [];
            Obj.WorkerException = [];
            if isa(Response, 'MException')
                throwAsCaller(Response);
            end
            %Obj.log(Func + "connected: %s", string(Obj.Connected));
        end
        

        %
        % Sends a directive to the worker.
        % NOTE:
        %  The worker doesn't have to be 'connected' to handle directives.
        %
        function Response = directive(Obj, Name, Value)

            db = dbstack(); Func = string([db(1).name ': ']);

            Directive = inst.SerialDirective;

            Directive.Name = Name;
            V = string.empty;
            if exist('Value', 'var')
                Directive.Value = Value;
                if isa(Value, 'double')
                    V = sprintf("%d", Value);
                elseif isa(Value, 'string')
                    V = Value;
                elseif isa(Value, 'logical')
                    V = string(logical(Value));
                end
                Directive.Value = Value;
            end
            if isempty(V)
                DirectiveAndValue = Name;
            else
                DirectiveAndValue = sprintf("%s=%s", Name, V);
            end

            if isempty(Obj.Job) || ~isvalid(Obj.Job) || Obj.Job.State ~= "running"
                throw(MException(Obj.ExceptionId, sprintf("The worker job is not valid, cannot send directive '%s'", DirectiveAndValue)));
            end
            
            Response = [];
            if isKey(Obj.Store, Obj.DirectiveResponseKey)
                remove(Obj.Store, Obj.DirectiveResponseKey); 
            end
            Obj.DirectiveResponseIsAvailable = false;

            Start = datetime('now');
            Obj.Store(Obj.DirectiveKey) = Directive;

            T0 = datetime('now');
            try
                while ~Obj.DirectiveResponseIsAvailable
                    T1 = datetime('now');
                    Dt = T1 - T0;
                    if Dt >= seconds(1)
                        Obj.log(Func + sprintf(": waiting for response to directive('%s')", DirectiveAndValue));
                        T0 = T1;
                    end
                    if isKey(Obj.Store, Obj.ExceptionKey)
                        ME = Obj.Store(Obj.ExceptionKey);
                        Response = ME;
                        logWorkerException(ME, 'directive');
                        remove(Obj.Store, Obj.ExceptionKey);
                        remove(Obj.Store, Obj.DirectiveKey);
                        return
                    end
                    pause(0.1);
                end
            catch ME
                Response = ME;
                remove(Obj.Store, Obj.DirectiveKey);
                return
            end

            Response = Obj.Store(Obj.DirectiveResponseKey);
            End = datetime('now');

            if isa(Response, 'double')
                R = sprintf("%d", Response);
            elseif isa(Response, 'string')
                R = Response;
            elseif isa(Response, 'logical')
                R = string(logical(Response));
            elseif isa(Response, 'MException')
                R = sprintf("exception: '%s'", Response.identifier);
            end

            Dt = End - Start;
            Dt.Format = 's';
            Obj.log(Func + " directive '%s', response: '%s', took %s", DirectiveAndValue, R, Dt);
            remove(Obj.Store, Obj.DirectiveResponseKey); 
            if isa(Response, 'MException')
                throwAsCaller(Response);
            end
        end            
        
        %
        % Sends a command to the worker.  The worker will send the command
        % to the device.
        %
        function Response = command(Obj, Command)
            arguments
                Obj
                Command inst.SerialCommand
            end

            db = dbstack(); Func = string([db(1).name ': ']);

            if ~Obj.Connected
                throw(MException(Obj.ExceptionId, Func + 'Not connected'));
            end

            if isempty(Obj.Store)
                throw(MException(this.ExceptionId, Func + 'Empty store'));
            end

            if isKey(Obj.Store, Obj.CommandKey)
                Obj.log('%s: worker is busy', Func)
                return
            end

            remove(Obj.Store, Obj.CommandResponseKey);
            Obj.CommandResponseIsAvailable = false;
            Start = datetime('now');
            Obj.Store(Obj.CommandKey) = Command;
            while ~Obj.CommandResponseIsAvailable % wait for response
                pause(0.1);
            end
            Response = Obj.Store(Obj.CommandResponseKey);
            End = datetime('now');
            Dt = End - Start;
            Dt.Format = 's';
            Obj.log(Func + " took %s", Dt);
            remove(Obj.Store, Obj.CommandResponseKey);

            % If any response was an exception, rethrow it
            for i = 1:numel(Response)
                if isa(Response(i).Value, 'MException')
                    throwAsCaller(Response(i).Value);
                end
            end

            remove(Obj.Store, Obj.CommandKey);
        end
        
        %
        % Reads the device's status response from the worker
        %
        function Response = get.Status(Obj)
            MillisToWait = milliseconds(100);

            if ~Obj.Connected
                throw(MException(Obj.ExceptionId, "Not connected"))
            end

            if ~Obj.Monitoring
                throw(MException(Obj.ExceptionId, "Not Monitoring"));
            end

            Start = datetime('now');
            while (datetime('now') - Start) < milliseconds(MillisToWait) && ~isKey(Obj.Store, Obj.StatusKey) % busy-wait till the response for 'status' comes back
                pause(10/1000); % 10 millis
            end

            if isKey(Obj.Store, Obj.StatusKey)
                Response = Obj.Store(Obj.StatusKey);
                for i = 1:numel(Response)
                    if isa(Response(i).Value, 'MException')
                        throwAsCaller(Response(i).Value)
                    end
                end
            else
                throw(MException(Obj.ExceptionId, sprintf("No 'status' from lower level within %d milliseconds", MillsToWait)));
            end
        end

        function set.Logging(Obj, Value)
            if Obj.Connected
                Obj.directive('logging', Value);
            end
            Obj.Logging = Value;
        end

        % Destructor
        function delete(Obj)
            db = dbstack(); Func = string([db(1).name ': ']);

            Obj.log(Func + 'entered');
            if isvalid(Obj.Job)
                disconnect(Obj)
                cancel(Obj.Job);
                delete(Obj.Job);
            end

            timers = timerfind('Name', 'WorkerCheckingTimer');
            for i = 1:numel(timers)
                stop(timers(i))
                delete(timers(i))
            end
        end

        function log(Obj, varargin)
            if ~Obj.Logging
                return
            end
            varargin{1} = "[upper] " + varargin{1};
            Obj.Logger.msgLog(LogLevel.Debug, varargin{:});
        end


        %
        % Periodical check that the lower process is still there.
        % If not, we disconnect and re-connect.
        %
        function onTimer(Obj)
            persistent TimerInCallback

            db = dbstack(); Func = string([db(1).name ': ']);

            if ~isempty(TimerInCallback)
                if TimerInCallback
                    return;
                else
                    TimerInCallback = true; %#ok<NASGU>
                end
            else
                TimerInCallback = true; %#ok<NASGU> 
            end
        
            if ~Obj.Connected
                TimerInCallback = false;
                return
            end
        
            Reason = string.empty;
            if isempty(Obj.Job)
                Reason = "isempty(Obj.Job)";
            elseif ~isvalid(Obj.Job)
                Reason = "~isvalid(Obj.Job)";
            elseif ~strcmp(Obj.Job.State, 'running')
                Reason = sprintf("Obj.Job (Id=%d) is not running , (State=%s)", Obj.Job.ID, Obj.Job.State);
            end

            if ~isempty(Reason)
                Obj.reconnect(Func + sprintf("The worker job looks dead (reason: %s)", Reason));
                TimerInCallback = false;
                return
            end
        
            task = Obj.Job.findTask;
            Reason = string.empty;
            if isempty(task)
                Reason = "isempty(task)";
            elseif ~strcmp(task.State, 'running')
                Reason = sprintf("task is not 'running' (State: '%s')", task.State);
            end

            if ~isempty(Reason)
                Obj.reconnect(Func + sprintf("The worker job looks dead (reason: %s)", Reason));
                TimerInCallback = false;
                return
            end

            if isKey(Obj.Store, Obj.ExceptionKey)
                Obj.logWorkerException(ObjStore(Obj.ExceptionKey), Func)
                remove(Obj.Store, Obj.ExceptionKey);
                % throw ?!?
            end

            TimerInCallback = false;
        end

    end

    methods(Hidden)
        %
        % Handle exceptions occurring in the worker process.
        %
        % Some exceptions may pertain to a serial line error (timeout,
        %  disconnection, etc.), in which case we may elect to reconnect.
        % Other exceptions may peratin to syntax errors, etc.
        %
        function handleWorkerException(Obj, ME)
            Obj.logWorkerException(Obj, ME, Func)
            Obj.WorkerException = ME;
            if strcmp(ME.identifier, "transportlib:transport:invalidConnectionState") && ...
                    strcmp(ME.message, "Invalid operation. Object must be connected to the serial port.")
                Obj.reconnect(sprintf("Seems like port '%s' has been disconnected", Obj.PortPath));
            end
        end

        function reconnect(Obj, reason)
            db = dbstack(); Func = string([db(1).name ': ']);

            Obj.log(Func + reason);
            cancel(Obj.Job);
            delete(Obj.Job);
            pause(2)
            Obj.connect
        end

        %
        % Client callback whenever the worker updates data in the Value Store
        %
        function onValueStoreUpdate(Obj, Store, Key)
            if strcmp(Key, Obj.CommandResponseKey)
                Obj.CommandResponseIsAvailable = true;
            elseif strcmp(Key, Obj.DirectiveResponseKey)
                Obj.DirectiveResponseIsAvailable = true;
            elseif strcmp(Key, Obj.ExceptionKey)
                if ~isKey(Store, Obj.DirectiveKey) && ~isKey(Store, Obj.CommandKey)
                    %
                    % An excepption occurred while no directive or command
                    %  were in progress
                    %
                    handleWorkerException(Store(Key));
                end
            end
        end

        function logWorkerException(Obj, ME, label)
            if ~Obj.Logging
                return
            end
            Obj.log("worker exception: [label: %s] %s:%s", label, ME.identifier, ME.message);
            stk = ME.stack;
            for i = 1:numel(stk)
                Obj.log(" %-35s %s:%d", stk(i).name, stk(i).file, stk(i).line);
            end
        end
    end

end


%
% Runs in the worker process
%
function makeSerialWorker(ArgsStruct)
    store = getCurrentValueStore;

    try
        inst.SerialWorker(ArgsStruct);
    catch ME
        % push the exception up to the upper layer
        store('exception') = ME; %#ok<NASGU> 
        return
    end
end

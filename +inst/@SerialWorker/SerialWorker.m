
classdef SerialWorker < handle
    properties(Constant=true, Hidden=true)  
        DefaultInterStatus                duration = seconds(15);
        DefaultTimeout                    duration = seconds(2);
        DefaultEndOfLoopDelay             duration = milliseconds(10);
    end

    properties
        Connected       logical = false;  % the serialport was successfuly connected
        Monitoring      logical = false;  % periodically get the device's status
        Device;                           % the actual serialport

        PortPath        string;           % serialport path
        PortSpeed       double;           % serialport BaudRate
        Timeout         duration;         % for serialport.readline() or serialport.read()
        Terminator      string = "CR";    % serialport.configureTerminator
        Eol             string = '\r';    % end-of-line string to be discarded
        InterStatus     duration;         % between status checks
        Validator       function_handle;  % validates replies from the serialport
        Reader          function_handle;  % to be used instead of serialport.readline or serialport.read
        Writer          function_handle;  % to be used instead of serialport.writeline or serialport.write
        ResponseTime    duration;         % how long to wait for a reply from the serialport
        InterCommand    duration;         % delay between multiple commands in the same transaction
        EndOfLoopDelay  duration;         % delay at the end of the perpetual worker loop (lets the cpu breathe :-)

        StatusCommand   inst.SerialCommand % a series of SerialCommand(s) to be send every 'Interval' to get the device's status
        Store;
        HasTerminator   logical = false;
    end

    properties(Hidden=true)
        ConnectRetries      double = Inf;
        ConnectRetryDelay   duration = seconds(5);
        Locked              logical = false;
        ExceptionId         string = 'OCS:SerialWorker';
        DeviceIsBusy        logical = false;
        LastInteraction     double;
    end

    properties(Constant=true)
        DirectiveKey         string = 'directive';
        DirectiveResponseKey string = 'directive-response';
        CommandKey           string = 'command';
        CommandResponseKey   string = 'command-response';
        ExceptionKey         string = 'exception';
    end

    methods
        function Obj = SerialWorker(WorkerArgs)
% arguments
%     Args.PortPath             string
%     Args.PortSpeed            double = 9600                 % [baud]
%     Args.Timeout              duration                      % [seconds]
%     Args.Terminator           string                        % [char]
%     Args.InterStatus          duration = milliseconds(20)   % [milliseconds] between status reads
%     Args.ResponseTime         duration = seconds(2)         % [milliseconds] to wait between sending something and getting a response
%     Args.StatusCommand        string                        % [string] to be sent for getting the status
%     Args.Validator            function_handle               % [func] returns true if the response is vallid, throws otherwise
%     Args.Reader               function_handle               % [func] user-specified serial device Reader
%     Args.Writer               function_handle               % [func] user-specified serial device writer
%     Args.InterCommand         duration;                     % [should be duration] to delay between sending a series of commands (millis)
%     Args.ConnectRetries       double;                       % [double] how many times to try to open the serialport (may be Inf)
%     Args.ConnectRetryDelay    duration;                     % [double] delay between connect retries (millis)
%     Args.EndOfLoopDelay       duration = seconds(.5);       % [double] delay at the end of the loop in the worker (millis)
% end

            Args = WorkerArgs(1);
            Func = "SerialWorker: ";
            
            if isfield(Args, 'PortPath');          Obj.PortPath          = Args.PortPath;                   end 
            if isfield(Args, 'PortSpeed');         Obj.PortSpeed         = Args.PortSpeed;                  end            
            if isfield(Args, 'Terminator');        Obj.Terminator        = Args.Terminator;                 end
            if isfield(Args, 'Timeout');           Obj.Timeout           = Args.Timeout;                    end            
            if isfield(Args, 'InterStatus');       Obj.InterStatus       = Args.InterStatus;                end            
            if isfield(Args, 'StatusCommand');     Obj.StatusCommand     = Args.StatusCommand;              end
            if isfield(Args, 'Validator');         Obj.Validator         = Args.Validator;                  end
            if isfield(Args, 'Reader');            Obj.Reader            = Args.Reader;                     end
            if isfield(Args, 'Writer');            Obj.Writer            = Args.Writer;                     end
            if isfield(Args, 'ResponseTime');      Obj.ResponseTime      = Args.ResponseTime;               end
            if isfield(Args, 'InterCommand');      Obj.InterCommand      = Args.InterCommand;               end
            if isfield(Args, 'ConnectRetries');    Obj.ConnectRetries    = Args.ConnectRetries;             end
            if isfield(Args, 'ConnectRetryDelay'); Obj.ConnectRetryDelay = Args.ConnectRetryDelay;          end
            if isfield(Args, 'Monitoring');        Obj.Monitoring        = Args.Monitoring;                 end
            if isfield(Args, 'EndOfLoopDelay');    Obj.EndOfLoopDelay    = Args.EndOfLoopDelay;             end

            Obj.log(Func + "PortPath: '%s'", Obj.PortPath)
                        
            Obj.HasTerminator = ~isempty(Obj.Terminator);

            % for the time-being, ONLY work with terminated-dialects
            if ~Obj.HasTerminator
                throw(MException(Obj.ExceptionId,'Must specify a terminator'))
            elseif isempty(Obj.Reader)
                Obj.Reader = @serialport.readline;                
            end

            switch Obj.Terminator
                case 'CR'
                    Obj.Eol = '\r';
                case 'LF'
                    Obj.Eol = '\n';
                case 'LF/CR'
                    Obj.Eol = '\n\r';
                case 'CR/LF'
                    Obj.Eol = '\r\n';
            end
            
            if Obj.Monitoring && numel(Obj.StatusCommand) < 1
                throw(MException(Obj.ExceptionId, "Must supply at least one 'StatusCommand' when 'Monitoring' is enabled!"));
            end

            if numel(Obj.StatusCommand) > 1
                Obj.Monitoring = true;
            end

            if isempty(Obj.EndOfLoopDelay)
                Obj.EndOfLoopDelay = Obj.DefaultEndOfLoopDelay;
            end

            if isempty(Obj.InterStatus)
                Obj.InterStatus = Obj.DefaultInterStatus;
            end

            if isempty(Obj.Timeout)
                Obj.Timeout = Obj.DefaultTimeout;
            end
            Obj.Device.Timeout = seconds(Obj.Timeout);

            if isempty(Obj.Reader)
                if ~Obj.HasTerminator
                    Obj.Reader = @serialport.read;
                else
                    Obj.Reader = @serialport.readline;
                end
            end
            
            if isempty(Obj.Writer)
                if ~Obj.HasTerminator
                    Obj.Writer = @internal.SerialPort.write;
                else
                    Obj.Writer = @internal.SerialPort.writeline;
                end
            end
            
            Obj.Store = getCurrentValueStore;
            Obj.DeviceIsBusy = false;

            try
                Obj.loop;
            catch ME
                if Obj.Connected
                    Obj.disconnect
                end
                Obj.Store(Obj.ExceptionKey) = ME;
                quit
            end
        end


        %
        % A serial worker's main loop
        %
        function loop(Obj)

            Func = 'SerialWorker.loop: '; % don't use dbstack() !!!

            Obj.log(Func + "entered");
            
            while true
                
                if isKey(Obj.Store, Obj.DirectiveKey)
                    %
                    % Directives are commands to the worker process (not to the device)
                    % A directive is a structure with two fields:
                    %  - Name: the directive itself
                    %  - Value: [optional]
                    %    - if empty:        this is a GET operation
                    %    - if not empty:    this is a SET operation
                    %
                    Directive = Obj.Store(Obj.DirectiveKey);
                    Msg = sprintf("directive: Name: '%s'", Directive.Name);
                    if ~isempty(Directive.Value)
                        Msg = Msg + sprintf(", Value: '%s'", string(Directive.Value));
                    else
                        Msg = Msg + sprintf(", Value: '<empty>'");
                    end
                    Obj.log(Func + Msg);
        
                    if strcmp(Directive.Name, 'quit')
                        if Obj.Connected
                            Obj.disconnect
                        end
                        remove(Obj.Store, Obj.DirectiveKey);
                        return % quit worker, Obj should close the worker process

                    elseif strcmp(Directive.Name, "connected")

                        if isempty(Directive.Value)  % get value of 'connected'
                            Obj.Store(Obj.DirectiveResponseKey) = Obj.Connected;
                            remove(Obj.Store, Obj.DirectiveKey);
                            continue;
                        end

                        for attemptNumber = 1:Obj.ConnectRetries
                            try
                                if Directive.Value
                                    % connected = true
                                    Obj.log(Func + "attempt#%d to connect to '%s' at %d", attemptNumber, Obj.PortPath, Obj.PortSpeed);
                                    Obj.Device = serialport(Obj.PortPath, Obj.PortSpeed);
                                    if ~isempty(Obj.Timeout)
                                        Obj.Device.Timeout = seconds(Obj.Timeout);
                                    end
                            
                                    if Obj.HasTerminator
                                        Obj.Device.configureTerminator(Obj.Terminator);
                                        if ~isempty(Obj.Reader)
                                            configureCallback(Obj.Device, 'terminator', @Obj.Reader);
                                        end
                                    end
                                    Obj.Connected = true;
                                    Obj.log(Func + "attempt#%d succeeded", attemptNumber);
                                    break;
                                else
                                    % connected = false
                                    if Obj.Connected
                                        Obj.disconnect
                                    end
                                end
                                Obj.Store(Obj.DirectiveResponseKey) = Obj.Connected;

                            catch ME
                                Obj.log(Func + "attempt#%d failed (error: %s)", attemptNumber, ME.message);
                                Obj.Connected = false;
                                Obj.Store(Obj.DirectiveResponseKey) = ME;
                            end

                            if ~isempty(Obj.ConnectRetryDelay)
                                pause(seconds(Obj.ConnectRetryDelay))
                            end
                        end

                        Obj.Store('connected') = Obj.Connected;
                        Obj.Store(Obj.DirectiveResponseKey) = Obj.Connected;
                        remove(Obj.Store, Obj.DirectiveKey);
                        continue;

                    elseif strcmp(Directive.Name, 'BaudRate')      % get/set speed
                        try
                            if ~isempty(Directive.Value)
                                if isa(Directive.Value, 'string')
                                    v = str2double(Directive.Value);
                                elseif isa(Directive.Value, 'double')
                                    v = Directive.Value;
                                else
                                    failDirectiveWithException(MException(Obj.ExceptionId, "Bad BaudRate must be either a 'string' or a 'double' (not a '%s')", class(Directive.Value)))
                                    continue
                                end
                                Obj.Device.BaudRate = v;
                            end
                            Obj.Store(Obj.DirectiveResponseKey) = Obj.Device.BaudRate;
                        catch ME
                            Obj.Store(Obj.DirectiveResponseKey) = ME;
                        end
                        remove(Obj.Store, Obj.DirectiveKey);
                        continue

                    elseif strcmp(Directive.Name, 'locked')
                        if ~isempty(Directive.Value)
                            Obj.Locked = Directive.Value;
                        end
                        Obj.Store(Obj.DirectiveResponseKey) = Obj.Locked;
                        remove(Obj.Store, Obj.DirectiveKey)
                        continue

                    elseif strcmp(Directive.Name, "monitoring")
                        if ~isempty(Directive.Value)
                            if Directive.Value && numel(Obj.StatusCommand) < 1
                                failDirectiveWithException(MException(Obj.ExceptionId, "Cannot set Monitoring to 'true' while 'StatusCommand' is not set"));
                                continue
                            end
                            Obj.Monitoring = Directive.Value;
%                             Obj.log(Func + sprintf("monitoring = %d", Obj.Monitoring));
                        end
%                         Obj.log(Func + "monitoring2");
                        Obj.Store(Obj.DirectiveResponseKey) = Obj.Monitoring;
                        remove(Obj.Store, Obj.DirectiveKey)
                        continue

                    else
                        failDirectiveWithException(MException(Obj.ExceptionId, sprintf("Invalid directive '%s'", Directive)));
                        continue
        
                    end
                end
        
                if Obj.Connected
                    %
                    % When connected:
                    % - if there's a pending command, send it to the device
                    % - otherwise, if the status interval has expired, send a status request to the device
                    %
                    if isKey(Obj.Store, Obj.CommandKey)
                        %
                        % Commands are structures with the fields:
                        %  - Commands: array of strings. Will be sent to the device with an (optional) delay in-between
                        %  - NoReplies: array of logicals. Whether to expect a reply for the respective command
                        %

                        if ~Obj.Locked
                            while Obj.DeviceIsBusy
                                Obj.log(Func + "for command: deviceIsBusy");
                                pause(.1);
                            end
                        end

                        Obj.Store(Obj.CommandResponseKey) = Obj.deviceTransaction(Obj.Store("command"));
                        Obj.LastInteraction = clock;
                        remove(Obj.Store, Obj.CommandKey);

                    else

                        if Obj.Monitoring && (isempty(Obj.LastInteraction) || round(etime(clock,Obj.LastInteraction) * 1000) > milliseconds(Obj.InterStatus))
                            if Obj.Locked
                                continue
                            end

                            while Obj.DeviceIsBusy
                                pause(.1);
                            end

                            Obj.Store('status') = Obj.deviceTransaction(Obj.StatusCommand);
                            Obj.LastInteraction = clock;
                        end
                    end
                end

                pause(seconds(Obj.EndOfLoopDelay)); % let the CPU breathe
            end
        end
        
        function Obj = disconnect(Obj)
            if isvalid(Obj.Device)
                delete(Obj.Device);
            end
            Obj.Connected = false;
            remove(Obj.Store, Obj.DirectiveResponseKey);
            remove(Obj.Store, 'response');
            remove(Obj.Store, 'connected');
        end

        %
        % Sends one or more commands to the device, as one transaction
        % 
        function Ret = deviceTransaction(Obj, Commands)
            arguments
                Obj
                Commands
            end

            Func = "deviceTransaction: ";
            Ncommands = numel(Commands);
            Ret = inst.SerialResponse;
            for i = 1:Ncommands
                Ret(i).Value = [];
                Ret(i).Time = datetime('now');
            end

            if ~Obj.Locked
                Obj.DeviceIsBusy = true;    % guard ON
            end

            for Idx = 1:Ncommands
                Obj.Device.flush

                Command = Commands(Idx).Command;
                NeedsReply = Commands(Idx).NeedsReply;

                Start = datetime('now');
                try
                    if (Obj.HasTerminator)
                        Obj.Device.writeline(Command);
                    else
                        Obj.Device.write(Command, length(Command));
                    end
                catch ME
                    Ret(Idx) = inst.SerialResponse(ME, datetime('now'));
                    continue
                end
    
                if NeedsReply
                    try
                        if Obj.HasTerminator
                            Line = Obj.Device.readline;
                        else
                            if ~isempty(Obj.ResponseTime)
                                pause(seconds(Obj.ResponseTime));
                            end
                            Line = Obj.Device.read(1024, uint8);
                        end
                    catch ME
                        Ret(Idx) = inst.SerialResponse(ME, datetime('now'));
                        Obj.log(Func + "command(%d): '%s' (exception: '%s')", Idx, Command, ME.message);
                        continue
                    end

                    if isempty(Line)
                        msg = sprintf("No response for command '%s' within %d seconds", Command, Obj.Device.Timeout);
                        Obj.log(Func + "command(%d): %15s (exception: '%s')", Idx, sprintf("'%s'", Command), msg);
                        Ret(Idx) = inst.SerialResponse(MException(Obj.ExceptionId, msg), datetime('now'));
                        continue
                    end
                    if endsWith(Line, Obj.Eol)
                        Line = replace(Line, Obj.Eol, '');
                    end
                        
                    if isa(Obj.Validator, 'function_handle') && ~isempty(Obj.Validator)
                        Obj.Validator(Line); % may throw exception
                    end   

                    Ret(Idx) = inst.SerialResponse(Line, datetime('now'));
                    Dt = Ret(Idx).Time - Start;
                    Dt.Format = "s";
                    Obj.log(Func + "command(%d): %15s, reply: '%s' (%s)", Idx, sprintf("'%s'", Command), Ret(Idx).Value, Dt);
                else
                    Ret(Idx) = inst.SerialResponse([], datetime('now'));
                    Dt = Ret(Idx).Time - Start;
                    Dt.Format = "s";
                    Obj.log(Func + "command(%d): %15s (no-reply) (%s)", Idx, sprintf("'%s'", Command), Dt);
                end

                if ~isempty(Obj.InterCommand) && Idx ~= Ncommands
                    Dt = Obj.InterCommand;
                    Obj.log(Func + "command(%d): %15s waiting InterCommand duration (%s)", Idx, sprintf("'%s'", Command), Dt);
                    pause(seconds(Obj.InterCommand));
                end
            end

            if ~Obj.Locked
                Obj.DeviceIsBusy = false;   % guard OFF
            end
        end

        function failDirectiveWithException(Obj, exception)
            remove(Obj.Store, Obj.DirectiveKey)
            Obj.Store(Obj.DirectiveResponseKey) = exception;
        end

        function log(Obj, varargin)
            persistent logger;
        
            if isempty(logger)
                Logdir = '/var/log/ocs';
                [~,~,~] = mkdir(Logdir);
                logger = MsgLogger(...
                    FileName=sprintf('%s/SerialDevice-%s.txt', Logdir, replace(Obj.PortPath, '/', '_')), ...
                    LoadConfig=false, ...
                    Console=false);
            end
        
            varargin{1} = "[lower] " + varargin{1};
            logger.msgLog(LogLevel.Debug, varargin{:});
        end

    end


end
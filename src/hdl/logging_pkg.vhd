/* @file logging_pkg.vhd
 * @brief Package which supports wide variety of logging levels
 * @author Justin Davis
 *
------------------------------------------------------------------------------*/
library ieee;       use ieee.std_logic_1164.all;
                    use ieee.numeric_std.all;

package logging_pkg is
    type logLevelType is (
        LOG_FATAL,      -- System cannot safely continue
        LOG_ERROR,      -- Incorrect result or violated protocol
        LOG_WARN,       -- Suspicious / unusual / non-ideal behavior
        LOG_INFO,       -- High-level progress indicators (test phase)
        LOG_DEBUG,      -- Mid-level progress indicators (key events)
        LOG_TRACE       -- Low-level progress indicators (every function call)
    );

    -- Messages with level >= currentLogLevel will be printed.
    shared variable currentLogLevel : logLevelType := LOG_INFO;

    -- Log a message, printed only if level >= CurrentLogLevel
    procedure logMsg(
        level : logLevelType;
        msg   : string
    );

    -- Simulation functions
    impure function check(test: std_logic; good: std_logic; preamble: string; level : logLevelType := LOG_WARN) return integer;
    impure function check(test: std_logic_vector; good: std_logic_vector; preamble: string; level : logLevelType := LOG_WARN) return integer;

end package logging_pkg;


package body logging_pkg is

    procedure logMsg(
        level : logLevelType;
        msg   : string
    ) is
    begin
        case level is
            when LOG_FATAL => 
                -- Always show FATAL, otherwise filter
                report "FATAL : " & msg severity note;

            when LOG_ERROR =>
                if currentLogLevel = LOG_TRACE or 
                   currentLogLevel = LOG_DEBUG or 
                   currentLogLevel = LOG_INFO  or 
                   currentLogLevel = LOG_WARN  or 
                   currentLogLevel = LOG_ERROR then
                    report "ERROR : " & msg severity note;
                end if;
                
            when LOG_WARN  => 
                if currentLogLevel = LOG_TRACE or 
                   currentLogLevel = LOG_DEBUG or 
                   currentLogLevel = LOG_INFO  or 
                   currentLogLevel = LOG_WARN  then
                    report "WARN : " & msg severity note;
                end if;
                
            when LOG_INFO  => 
                if currentLogLevel = LOG_TRACE or 
                   currentLogLevel = LOG_DEBUG or 
                   currentLogLevel = LOG_INFO then
                    report "INFO : " & msg severity note;
                end if;
                
            when LOG_DEBUG => 
                if currentLogLevel = LOG_TRACE or 
                   currentLogLevel = LOG_DEBUG then
                    report "DEBUG : " & msg severity note;
                end if;
                
            when LOG_TRACE => 
                if currentLogLevel = LOG_TRACE then
                    report "TRACE : " & msg severity note;
                end if;
                
        end case;
    end procedure;

    ----------------------------------------------------------------------------
    -- check - checks if the two inputs are the same.  Return 0 if they are.
    --   if they are not, it returns at 1 (to increase error counter)
    --   also generates report if they are not
    ----------------------------------------------------------------------------
    impure function check(test: std_logic; good: std_logic; preamble: string; level : logLevelType := LOG_WARN) return integer is
    begin
        if test/=good then
            logMsg(level, preamble & " MISMATCH EXPECTED (" & to_string(good) & ") RECEVIED (" & to_string(test) & ")");
            return 1;
        end if;
        return 0;
    end function check;
    
    impure function check(test: std_logic_vector; good: std_logic_vector; preamble: string; level : logLevelType := LOG_WARN) return integer is
    begin
        if test/=good then
            logMsg(level, preamble & " MISMATCH EXPECTED (" & to_hstring(good) & ") RECEVIED (" & to_hstring(test) & ")");
            return 1;
        end if;
        return 0;
    end function check;

end package body logging_pkg;
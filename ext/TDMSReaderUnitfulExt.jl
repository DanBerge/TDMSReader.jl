"Unitful for TDMS files: a channel's samples as quantities in the unit it names."
module TDMSReaderUnitfulExt

using TDMSReader: TDMSReader, Channel
import Unitful

function TDMSReader.withunits(ch::Channel)
    haskey(ch.props, "unit_string") ||
        throw(ArgumentError("the channel has no unit_string property; give the unit: withunits(ch, u\"V\")"))
    s = ch.props["unit_string"]
    u = try
        Unitful.uparse(s)
    catch
        throw(ArgumentError("Unitful does not read the unit_string $(repr(s)); give the unit: withunits(ch, u\"V\")"))
    end
    TDMSReader.withunits(ch, u)
end
TDMSReader.withunits(ch::Channel, u::Unitful.Units) = ch.data .* u

end

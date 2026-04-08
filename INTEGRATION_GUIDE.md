# TraxxTool ↔ QLC+ Integration Guide

**Comprehensive Implementation Guide for Dynamic Bridging Between TraxxTool and Q Light Controller Plus**

This document provides step-by-step instructions for implementing full integration between TraxxTool (backing track orchestration tool written in Python/PyQt6) and QLC+ (DMX lighting control, C++/Qt). The guide is designed to be thorough enough for another developer to implement without requiring clarification.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Concepts and Template Workspace Model](#core-concepts-and-template-workspace-model)
3. [QLC+ Fade System Integration](#qlc-fade-system-integration)
4. [Data Model Extensions](#data-model-extensions)
5. [QXW Workspace Generation](#qxw-workspace-generation)
6. [MIDI Light Cue Generation](#midi-light-cue-generation)
7. [StageCue Integration](#stagecue-integration)
8. [Implementation Roadmap](#implementation-roadmap)

---

## Architecture Overview

### High-Level Integration Flow

```
TraxxTool (Python/PyQt6)
  ↓
User creates/edits guide markers with lighting cues
  ↓
Compiler reads template.qxw (created in QLC+ desktop)
  ↓
Generates new Show Functions with fade properties
  ↓
Outputs final.qxw (template + new Shows)
  ↓
Generates MIDI file with Program Changes on channel 15
  ↓
Generates videocues.json for StageCue (Node.js server)
  ↓
StageBox (Pixel 8 Pro running VolksPC/Debian)
  ↓
StageCue listens for MIDI PCs → triggers QLC+ via WebSocket
  ↓
QLC+ Show Functions execute with fade curves and timing
```

### Key Principles

1. **Template Workspace Model**: TraxxTool does NOT create QLC+ fixtures, scenes, or functions. Instead:
   - A human creates a template workspace (`template.qxw`) in QLC+ desktop
   - This template contains all fixtures, basic scenes, and lighting functions
   - TraxxTool imports this read-only template
   - TraxxTool generates only Show objects with ShowFunction clips (timeline items)
   - Final output merges template + new Shows into `final.qxw`

2. **Separation of Concerns**:
   - QLC+ desktop = fixture/scene/function definitions (human-created)
   - TraxxTool = dynamic Show creation based on backing track structure
   - StageCue = MIDI→QLC+ bridge on StageBox hardware

3. **Timeline Synchronization**:
   - Guide markers in TraxxTool map to lighting cues
   - Each cue specifies a QLC+ function and fade parameters
   - MIDI Program Changes trigger QLC+ functions
   - Fade curves (linear or equal-power) interpolate between on/off states

---

## Core Concepts and Template Workspace Model

### QLC+ Workspace Structure (QXW)

The QXW file is XML-based and contains:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE FixtureDefinition>
<QLC version="4.13.0">
  <Fixtures>
    <!-- Fixture definitions (created in QLC+ desktop) -->
  </Fixtures>
  <Functions>
    <!-- Scene, Chaser, Show, RGBMatrix functions -->
  </Functions>
  <Channels>
    <!-- Channel groups, fixture channels -->
  </Channels>
</QLC>
```

### Show Structure

Each Show function contains:

```xml
<Function type="Show" id="X" name="Song1_Lighting">
  <Speed fade="X" duration="X"/>
  <ShowTrack name="Track1">
    <ShowFunction functionID="Y" startTime="0" duration="5000" 
                  FadeIn="1000" FadeOut="500"/>
  </ShowTrack>
  <ShowTrack name="Track2">
    <ShowFunction functionID="Z" startTime="2000" duration="3000"
                  FadeIn="0" FadeOut="1500"/>
  </ShowTrack>
</Function>
```

Key attributes:
- `startTime`: When the clip starts (milliseconds)
- `duration`: Total clip duration (milliseconds)
- `FadeIn`: Fade-in duration (milliseconds, added recently)
- `FadeOut`: Fade-out duration (milliseconds, added recently)
- `functionID`: Reference to a Scene or other function

### Template Workspace Workflow

1. **Human creates template.qxw in QLC+ desktop**:
   - Adds all DMX fixtures
   - Creates basic Scenes (e.g., "Stage_Warm", "Stage_Cool", "Dimmer_Low")
   - Sets RGB/intensity values for each scene
   - Notes the function IDs for later reference

2. **TraxxTool imports template.qxw**:
   - Parses XML to extract available functions and their metadata
   - Stores list of available functions in memory
   - Does NOT modify fixture or scene definitions

3. **User creates guide markers in TraxxTool**:
   - Places markers on timeline
   - Each marker specifies: timing, duration, function reference, fade times
   - Markers automatically sync with backing track audio

4. **Compiler generates final.qxw**:
   - Reads template.qxw
   - Creates new Show function(s) with ShowTracks and ShowFunctions
   - Populates ShowFunctions with data from guide markers
   - Preserves all template fixtures and base functions
   - Writes merged output to final.qxw

---

## QLC+ Fade System Integration

### Recent Changes (Merged from QLC+ Master)

The fade system was recently added to QLC+ master branch. Key components:

#### ShowFunction Model (C++ Backend)

File: `/home/user/qlcplus/engine/src/showfunction.h` and `showfunction.cpp`

Properties:
```cpp
quint32 m_fadeInDuration;   // Fade-in duration in milliseconds
quint32 m_fadeOutDuration;  // Fade-out duration in milliseconds
```

Methods:
```cpp
void setFadeInDuration(quint32 fadeIn);
void setFadeOutDuration(quint32 fadeOut);
quint32 fadeInDuration() const;
quint32 fadeOutDuration() const;
```

Signals:
```cpp
void fadeInDurationChanged(quint32 duration);
void fadeOutDurationChanged(quint32 duration);
```

XML Serialization:
```cpp
// In saveXML():
if (m_fadeInDuration > 0)
  tag.writeAttribute(KXMLShowFunctionFadeIn, QString::number(m_fadeInDuration));
if (m_fadeOutDuration > 0)
  tag.writeAttribute(KXMLShowFunctionFadeOut, QString::number(m_fadeOutDuration));

// In loadXML():
m_fadeInDuration = tag.attributes().value(KXMLShowFunctionFadeIn).toString().toUInt();
m_fadeOutDuration = tag.attributes().value(KXMLShowFunctionFadeOut).toString().toUInt();
```

#### ShowManager Backend

File: `/home/user/qlcplus/qmlui/showmanager.h`

Key methods for fade manipulation:
```cpp
Q_INVOKABLE void setShowItemFadeIn(ShowFunction *sf, int fadeIn);
Q_INVOKABLE void setShowItemFadeOut(ShowFunction *sf, int fadeOut);
```

Crossfade support:
```cpp
Q_INVOKABLE ShowFunction *findAdjacentClipBefore(ShowFunction *sf) const;
Q_INVOKABLE bool applyCrossfade(ShowFunction *sfBefore, ShowFunction *sfAfter, 
                                int crossfadeDuration);
```

Equal-power fade curves:
```cpp
Q_PROPERTY(bool equalPowerFades READ equalPowerFades WRITE setEqualPowerFades 
           NOTIFY equalPowerFadesChanged)
```

#### QML UI Components

Files: 
- `/home/user/qlcplus/qmlui/qml/showmanager/ShowItem.qml` (visual representation)
- `/home/user/qlcplus/qmlui/qml/showmanager/TimingUtils.qml` (timing editor)

ShowItem properties:
```qml
property int fadeInDuration
property int fadeOutDuration
property real fadeInWidth      // Pixel width of fade handle
property real fadeOutWidth
property ShowFunction adjacentClipBefore
property int crossfadeDuration
```

TimingUtils methods:
```qml
function applyAbsoluteValue(fieldId, value)
function applyRelativeValue(fieldId, delta)
```

Supports h:m:s:ms spinners for precise timing.

### Fade Curve Algorithms

#### Linear Fade
Simple linear interpolation from 0 to intensity:
```
value(t) = intensity * (t / fadeDuration)
```

#### Equal-Power Fade
Non-linear curve that preserves perceived brightness when crossfading:
```
value(t) = intensity * sqrt(t / fadeDuration)
```

This prevents the common "dip" in brightness during crossfades.

---

## Data Model Extensions

### TraxxTool Models to Extend

#### 1. GuideMarker Dataclass

File: `/home/user/traxxtool/src/core/models.py`

Current structure:
```python
@dataclass
class GuideMarker:
    text: str
    time_ms: int
    duration: int
    type: str  # "guide", "pedal", "light"
    value: Optional[str] = None
    peak_offset_ms: int = 0
```

**Extend with lighting-specific fields:**
```python
@dataclass
class GuideMarker:
    text: str
    time_ms: int
    duration: int
    type: str  # "guide", "pedal", "light"
    value: Optional[str] = None
    peak_offset_ms: int = 0
    
    # NEW: Lighting cue fields (only populated if type == "light")
    qlc_function_id: Optional[int] = None      # ID of QLC+ function to trigger
    qlc_function_name: Optional[str] = None    # Human-readable name for reference
    fade_in_ms: int = 0                        # Fade-in duration
    fade_out_ms: int = 0                       # Fade-out duration
    video_file: Optional[str] = None           # Associated video cue file
    crossfade_duration_ms: int = 0             # Overlap with previous clip
```

#### 2. New LightingCue Dataclass

Add to `/home/user/traxxtool/src/core/models.py`:

```python
@dataclass
class LightingCue:
    """Represents a lighting cue for QLC+ integration."""
    
    # Timing and duration
    start_time_ms: int              # When cue starts
    duration_ms: int                # How long the function runs
    
    # QLC+ function reference
    qlc_function_id: int            # ID of Scene/Chaser/etc
    qlc_function_name: str          # Scene name like "Stage_Warm"
    
    # Fade properties
    fade_in_ms: int = 0             # Fade-in duration (0 = instant)
    fade_out_ms: int = 0            # Fade-out duration (0 = instant)
    
    # Optional video integration
    video_file: Optional[str] = None # Video cue file for StageCue
    
    # Optional crossfade with previous clip
    crossfade_with_previous: bool = False
    crossfade_duration_ms: int = 0
    
    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "startTime": self.start_time_ms,
            "duration": self.duration_ms,
            "functionId": self.qlc_function_id,
            "functionName": self.qlc_function_name,
            "fadeIn": self.fade_in_ms,
            "fadeOut": self.fade_out_ms,
            "videoFile": self.video_file,
            "crossfade": {
                "enabled": self.crossfade_with_previous,
                "duration": self.crossfade_duration_ms
            } if self.crossfade_with_previous else None
        }
```

#### 3. TemplateWorkspaceInfo Dataclass

Add to `/home/user/traxxtool/src/core/models.py`:

```python
@dataclass
class TemplateWorkspaceInfo:
    """Information extracted from template.qxw."""
    
    template_path: str                  # Path to template.qxw
    available_functions: dict           # {function_id: function_name}
    available_scenes: dict              # {scene_id: scene_name}
    fixtures: list                      # List of fixture definitions
    channel_count: int                  # Total DMX channels
    
    def get_function_by_name(self, name: str) -> Optional[int]:
        """Look up function ID by name."""
        for func_id, func_name in self.available_functions.items():
            if func_name == name:
                return func_id
        return None
```

---

## QXW Workspace Generation

### Architecture

Create new module: `/home/user/traxxtool/src/core/qxw_generator.py`

This module handles:
1. Loading template.qxw
2. Parsing XML structure
3. Creating Show functions from lighting cues
4. Merging with template
5. Writing final.qxw

### Implementation

```python
# qxw_generator.py

import xml.etree.ElementTree as ET
from xml.dom import minidom
from pathlib import Path
from typing import List, Optional
from models import LightingCue, TemplateWorkspaceInfo


class QXWGenerator:
    """Generates QLC+ workspace files with lighting shows."""
    
    def __init__(self, template_path: str):
        """
        Initialize with template workspace path.
        
        Args:
            template_path: Path to template.qxw
        """
        self.template_path = Path(template_path)
        self.tree = None
        self.root = None
        self._load_template()
    
    def _load_template(self):
        """Load and parse template.qxw."""
        try:
            self.tree = ET.parse(self.template_path)
            self.root = self.tree.getroot()
        except Exception as e:
            raise ValueError(f"Failed to load template: {e}")
    
    def extract_template_info(self) -> TemplateWorkspaceInfo:
        """
        Extract available functions from template.
        
        Returns:
            TemplateWorkspaceInfo object with function mappings
        """
        functions = {}
        scenes = {}
        fixtures = []
        
        # Extract functions
        functions_elem = self.root.find("Functions")
        if functions_elem is not None:
            for func_elem in functions_elem.findall("Function"):
                func_id = func_elem.get("id")
                func_name = func_elem.get("name")
                func_type = func_elem.get("type")
                
                functions[int(func_id)] = func_name
                
                # Track scenes separately
                if func_type == "Scene":
                    scenes[int(func_id)] = func_name
        
        # Extract fixtures
        fixtures_elem = self.root.find("Fixtures")
        if fixtures_elem is not None:
            for fixture_elem in fixtures_elem.findall("Fixture"):
                fixtures.append({
                    "id": fixture_elem.get("id"),
                    "name": fixture_elem.get("name")
                })
        
        return TemplateWorkspaceInfo(
            template_path=str(self.template_path),
            available_functions=functions,
            available_scenes=scenes,
            fixtures=fixtures,
            channel_count=512  # Standard DMX universe
        )
    
    def create_show(self, show_name: str, cues: List[LightingCue],
                    use_equal_power_fades: bool = False) -> ET.Element:
        """
        Create a Show element from lighting cues.
        
        Args:
            show_name: Name for the new show
            cues: List of LightingCue objects
            use_equal_power_fades: Whether to use equal-power vs linear fades
        
        Returns:
            ET.Element representing the Show function
        """
        # Find next available function ID
        next_id = self._get_next_function_id()
        
        # Create Show element
        show = ET.Element("Function")
        show.set("type", "Show")
        show.set("id", str(next_id))
        show.set("name", show_name)
        
        # Add Speed element
        speed = ET.SubElement(show, "Speed")
        speed.set("fade", "0")
        speed.set("duration", "0")
        
        # Group cues by track (for organization)
        # Default: one track per unique function
        tracks_by_function = {}
        for cue in cues:
            func_id = cue.qlc_function_id
            if func_id not in tracks_by_function:
                tracks_by_function[func_id] = []
            tracks_by_function[func_id].append(cue)
        
        # Create ShowTrack for each unique function
        for func_idx, (func_id, cues_for_track) in enumerate(tracks_by_function.items()):
            track = ET.SubElement(show, "ShowTrack")
            track.set("name", f"Track{func_idx + 1}")
            
            # Add ShowFunction elements (clips)
            for cue in cues_for_track:
                clip = ET.SubElement(track, "ShowFunction")
                clip.set("functionID", str(cue.qlc_function_id))
                clip.set("startTime", str(cue.start_time_ms))
                clip.set("duration", str(cue.duration_ms))
                
                # Add fade properties
                if cue.fade_in_ms > 0:
                    clip.set("FadeIn", str(cue.fade_in_ms))
                if cue.fade_out_ms > 0:
                    clip.set("FadeOut", str(cue.fade_out_ms))
        
        return show
    
    def add_show_to_template(self, show_element: ET.Element):
        """Add a Show function to the template."""
        functions = self.root.find("Functions")
        if functions is None:
            functions = ET.SubElement(self.root, "Functions")
        
        functions.append(show_element)
    
    def save(self, output_path: str):
        """
        Save modified workspace to file.
        
        Args:
            output_path: Path where to write final.qxw
        """
        # Pretty print
        xml_str = minidom.parseString(ET.tostring(self.root)).toprettyxml(indent="  ")
        
        # Remove empty lines
        xml_lines = [line for line in xml_str.split('\n') if line.strip()]
        
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(xml_lines))
    
    def _get_next_function_id(self) -> int:
        """Find the next available function ID."""
        max_id = 0
        functions = self.root.find("Functions")
        if functions is not None:
            for func_elem in functions.findall("Function"):
                func_id = int(func_elem.get("id", 0))
                max_id = max(max_id, func_id)
        return max_id + 1
```

### Integration with Compiler

Update `/home/user/traxxtool/src/core/compiler.py`:

```python
# In St4bCompiler class

def compile_with_lighting(self, template_qxw_path: str, output_dir: str):
    """
    Compile backing track with integrated lighting cues.
    
    Args:
        template_qxw_path: Path to template.qxw created in QLC+
        output_dir: Directory for output files
    """
    from qxw_generator import QXWGenerator
    from models import LightingCue
    
    # Initialize generator
    gen = QXWGenerator(template_qxw_path)
    template_info = gen.extract_template_info()
    
    # Extract lighting cues from song markers
    lighting_cues = self._extract_lighting_cues()
    
    # Convert guide markers to LightingCue objects
    qlc_cues = []
    for marker in self.song_model.guide_markers:
        if marker.type == "light" and marker.qlc_function_id is not None:
            cue = LightingCue(
                start_time_ms=marker.time_ms,
                duration_ms=marker.duration,
                qlc_function_id=marker.qlc_function_id,
                qlc_function_name=marker.qlc_function_name or "",
                fade_in_ms=marker.fade_in_ms,
                fade_out_ms=marker.fade_out_ms,
                video_file=marker.video_file,
                crossfade_with_previous=(marker.crossfade_duration_ms > 0),
                crossfade_duration_ms=marker.crossfade_duration_ms
            )
            qlc_cues.append(cue)
    
    # Sort by start time
    qlc_cues.sort(key=lambda c: c.start_time_ms)
    
    # Create show
    show_name = f"{self.song_model.title}_Lighting"
    show_elem = gen.create_show(show_name, qlc_cues)
    gen.add_show_to_template(show_elem)
    
    # Save final workspace
    output_qxw = Path(output_dir) / "final.qxw"
    gen.save(str(output_qxw))
    
    return str(output_qxw)
```

---

## MIDI Light Cue Generation

### Architecture

Extend `/home/user/traxxtool/src/core/midi_generator.py` to support lighting markers.

### Implementation

```python
# In midi_generator.py

class MidiGenerator:
    """Generates MIDI files with lighting cues."""
    
    def __init__(self):
        self.tracks = []
        self.current_time = 0
    
    def add_light_cue(self, time_ms: int, function_id: int, velocity: int = 100):
        """
        Add a lighting cue as a MIDI Program Change.
        
        MIDI mapping:
        - Channel: 15 (0-indexed, so channel 16 in DAW)
        - Message: Program Change
        - Value: function_id (must be 0-127)
        
        Args:
            time_ms: Time in milliseconds
            function_id: QLC+ function ID (must fit in 0-127 range)
            velocity: Optional velocity value
        """
        if function_id > 127:
            print(f"WARNING: Function ID {function_id} exceeds MIDI PC range (0-127)")
            function_id = function_id % 128  # Wrap around
        
        # Convert milliseconds to MIDI ticks
        # Standard: 480 ticks per quarter note, 120 BPM = 2 beats per second
        ticks = int((time_ms / 1000) * 480 * 2)
        
        # Program Change on channel 15
        message = self._create_program_change(function_id, channel=15)
        self.tracks.append((ticks, message))
    
    def add_crossfade_markers(self, start_ms: int, duration_ms: int):
        """
        Add CC messages for crossfade envelope.
        
        Sends:
        - CC7 (Volume) envelope during fade
        """
        start_ticks = int((start_ms / 1000) * 480 * 2)
        end_ticks = int(((start_ms + duration_ms) / 1000) * 480 * 2)
        
        # Fade in: CC7 from 0 to 127
        # Fade out: CC7 from 127 to 0
        # Divide duration into 10 steps
        steps = 10
        step_duration = (end_ticks - start_ticks) // steps
        
        for i in range(steps + 1):
            tick = start_ticks + (i * step_duration)
            value = int((i / steps) * 127)
            cc_msg = self._create_cc(7, value, channel=15)
            self.tracks.append((tick, cc_msg))
    
    def _create_program_change(self, program: int, channel: int = 0) -> bytes:
        """Create MIDI Program Change message."""
        return bytes([0xC0 | channel, program])
    
    def _create_cc(self, controller: int, value: int, channel: int = 0) -> bytes:
        """Create MIDI Control Change message."""
        return bytes([0xB0 | channel, controller, value])
    
    def write_file(self, filepath: str, bpm: int = 120):
        """
        Write MIDI file with light cues.
        
        Uses midiutil library for MIDI Format 0 output.
        """
        from midiutil import MIDIFile
        
        mf = MIDIFile(1)  # 1 track
        track = 0
        channel = 15
        time = 0
        
        # Sort events by time
        events = sorted(self.tracks, key=lambda x: x[0])
        
        for tick, message in events:
            # Convert tick to beat
            beat = tick / 480
            
            # Extract message type
            status = message[0] >> 4
            
            if status == 0xC:  # Program Change
                program = message[1]
                mf.addProgramChange(track, channel, beat, program)
            elif status == 0xB:  # Control Change
                controller = message[1]
                value = message[2]
                mf.addControllerEvent(track, channel, beat, controller, value)
        
        with open(filepath, 'wb') as f:
            mf.writeFile(f)
```

### Integration with Compiler

```python
# In St4bCompiler.compile_with_lighting()

# Generate MIDI with light cues
midi_gen = MidiGenerator()

for cue in qlc_cues:
    # Add program change at cue start
    midi_gen.add_light_cue(cue.start_time_ms, cue.qlc_function_id)
    
    # Add crossfade markers if applicable
    if cue.crossfade_with_previous:
        midi_gen.add_crossfade_markers(cue.start_time_ms, cue.crossfade_duration_ms)

output_midi = Path(output_dir) / "lighting_cues.mid"
midi_gen.write_file(str(output_midi), bpm=self.song_model.bpm)
```

---

## StageCue Integration

### videocues.json Generation

StageCue expects a `videocues.json` file mapping MIDI Program Changes to video files.

Add to `/home/user/traxxtool/src/core/qxw_generator.py`:

```python
class VideoCuesGenerator:
    """Generates videocues.json for StageCue."""
    
    def __init__(self, lighting_cues: List[LightingCue]):
        self.cues = lighting_cues
    
    def generate(self) -> dict:
        """
        Generate videocues.json structure.
        
        Returns:
            Dictionary ready for JSON serialization
        """
        cues_by_id = {}
        
        for cue in self.cues:
            if cue.video_file:
                cue_entry = {
                    "videoFile": cue.video_file,
                    "startTime": cue.start_time_ms,
                    "duration": cue.duration_ms,
                    "fadeIn": cue.fade_in_ms,
                    "fadeOut": cue.fade_out_ms
                }
                
                func_id = cue.qlc_function_id
                if func_id not in cues_by_id:
                    cues_by_id[func_id] = []
                
                cues_by_id[func_id].append(cue_entry)
        
        return {
            "version": "1.0",
            "cues": cues_by_id
        }
    
    def save(self, output_path: str):
        """Save to JSON file."""
        import json
        data = self.generate()
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)
```

### StageCue Server Integration

The StageCue Node.js server (running on StageBox) receives MIDI and:

1. Parses Program Change on channel 15
2. Maps PC value to QLC+ function ID
3. Sends WebSocket command to QLC+: `QLC+API|setFunctionStatus|{functionId}|1`
4. Optionally triggers video playback via browser API

Current implementation in `/home/user/stagebox/stagecue/server.js` already handles this. TraxxTool provides:
- Final MIDI file with Program Changes
- videocues.json with video file mappings
- Final QXW workspace with Shows containing proper fade settings

---

## Implementation Roadmap

### Phase 1: Data Model Extensions

**Files to modify:**
1. `/home/user/traxxtool/src/core/models.py`
   - Extend `GuideMarker` with lighting fields
   - Add `LightingCue` dataclass
   - Add `TemplateWorkspaceInfo` dataclass

**Estimated: 2-3 hours**

Example implementation:
```python
# Add to models.py

@dataclass
class GuideMarker:
    text: str
    time_ms: int
    duration: int
    type: str
    value: Optional[str] = None
    peak_offset_ms: int = 0
    
    # Lighting fields
    qlc_function_id: Optional[int] = None
    qlc_function_name: Optional[str] = None
    fade_in_ms: int = 0
    fade_out_ms: int = 0
    video_file: Optional[str] = None
    crossfade_duration_ms: int = 0
```

### Phase 2: Template Workspace Loading

**Files to create:**
1. `/home/user/traxxtool/src/core/workspace_loader.py`

**Functionality:**
- Load template.qxw and parse XML
- Extract available functions/scenes
- Validate template structure
- Provide lookup utilities

```python
class TemplateWorkspaceLoader:
    def __init__(self, template_path: str):
        self.path = template_path
        self.info = None
    
    def load(self) -> TemplateWorkspaceInfo:
        """Parse template and return metadata."""
        # Implementation using xml.etree
        pass
    
    def get_function_by_name(self, name: str) -> Optional[int]:
        """Lookup function ID by name."""
        pass
```

**Estimated: 2-3 hours**

### Phase 3: QXW Generation

**Files to create:**
1. `/home/user/traxxtool/src/core/qxw_generator.py`

**Functionality:**
- Load template.qxw
- Create Show elements with ShowTracks and ShowFunctions
- Merge with template
- Write final.qxw with proper XML structure

**Estimated: 4-5 hours**

### Phase 4: MIDI Generation for Lighting

**Files to modify:**
1. `/home/user/traxxtool/src/core/midi_generator.py`

**Functionality:**
- Extend existing MidiGenerator
- Add `add_light_cue()` method for Program Changes
- Add `add_crossfade_markers()` for envelope CCs
- Ensure channel 15 usage

**Estimated: 2-3 hours**

### Phase 5: StageCue Integration

**Files to create:**
1. `/home/user/traxxtool/src/core/videocues_generator.py`

**Functionality:**
- Generate videocues.json from LightingCue list
- Map function IDs to video files
- Preserve timing and fade information

**Estimated: 1-2 hours**

### Phase 6: UI Integration

**Files to modify:**
1. `/home/user/traxxtool/src/gui/workbench.py` (marker editor)
2. Create new `marker_editor_panel.py` for lighting properties

**Functionality:**
- When user creates/edits "light" type marker, show additional fields:
  - Dropdown to select QLC+ function (from template)
  - Spinboxes for fade_in_ms and fade_out_ms
  - Textfield for video_file
  - Checkbox for crossfade with previous

**Estimated: 3-4 hours**

### Phase 7: Compiler Integration

**Files to modify:**
1. `/home/user/traxxtool/src/core/compiler.py`

**Functionality:**
- Add `compile_with_lighting()` method
- Call QXWGenerator to create final.qxw
- Call MidiGenerator to create lighting_cues.mid
- Call VideoCuesGenerator to create videocues.json
- Ensure all outputs in staging directory

**Estimated: 2-3 hours**

### Phase 8: Testing & Integration

**Estimated: 4-5 hours**

Test cases:
1. Load template.qxw correctly
2. Extract function list accurately
3. Create valid QXW with Shows
4. MIDI file contains correct Program Changes on channel 15
5. videocues.json has correct structure
6. Round-trip: modify in TraxxTool → compile → load in QLC+ → plays correctly

**Total Estimated: 20-28 hours**

---

## Step-by-Step Implementation Instructions

### 1. Extend Data Models

Edit `/home/user/traxxtool/src/core/models.py`:

```python
from dataclasses import dataclass, field
from typing import Optional, List, Dict

# Update existing GuideMarker
@dataclass
class GuideMarker:
    text: str
    time_ms: int
    duration: int
    type: str  # "guide", "pedal", "light"
    value: Optional[str] = None
    peak_offset_ms: int = 0
    
    # NEW: Lighting cue properties
    qlc_function_id: Optional[int] = None
    qlc_function_name: Optional[str] = None
    fade_in_ms: int = 0
    fade_out_ms: int = 0
    video_file: Optional[str] = None
    crossfade_duration_ms: int = 0

# NEW: Lighting cue model
@dataclass
class LightingCue:
    start_time_ms: int
    duration_ms: int
    qlc_function_id: int
    qlc_function_name: str
    fade_in_ms: int = 0
    fade_out_ms: int = 0
    video_file: Optional[str] = None
    crossfade_with_previous: bool = False
    crossfade_duration_ms: int = 0
    
    def to_dict(self) -> dict:
        return {
            "startTime": self.start_time_ms,
            "duration": self.duration_ms,
            "functionId": self.qlc_function_id,
            "functionName": self.qlc_function_name,
            "fadeIn": self.fade_in_ms,
            "fadeOut": self.fade_out_ms,
            "videoFile": self.video_file,
            "crossfade": {
                "enabled": self.crossfade_with_previous,
                "duration": self.crossfade_duration_ms
            } if self.crossfade_with_previous else None
        }

# NEW: Template workspace metadata
@dataclass
class TemplateWorkspaceInfo:
    template_path: str
    available_functions: Dict[int, str]  # {id: name}
    available_scenes: Dict[int, str]
    fixtures: List[Dict]
    channel_count: int
    
    def get_function_by_name(self, name: str) -> Optional[int]:
        for func_id, func_name in self.available_functions.items():
            if func_name == name:
                return func_id
        return None
```

### 2. Create Template Workspace Loader

Create `/home/user/traxxtool/src/core/workspace_loader.py`:

```python
import xml.etree.ElementTree as ET
from pathlib import Path
from models import TemplateWorkspaceInfo

class TemplateWorkspaceLoader:
    def __init__(self, template_path: str):
        self.template_path = Path(template_path)
        self.tree = None
        self.root = None
    
    def load(self) -> TemplateWorkspaceInfo:
        """Load template and extract metadata."""
        self.tree = ET.parse(self.template_path)
        self.root = self.tree.getroot()
        
        functions = {}
        scenes = {}
        fixtures = []
        
        # Extract functions
        functions_elem = self.root.find("Functions")
        if functions_elem is not None:
            for func_elem in functions_elem.findall("Function"):
                func_id = int(func_elem.get("id", 0))
                func_name = func_elem.get("name", "")
                func_type = func_elem.get("type", "")
                
                functions[func_id] = func_name
                
                if func_type == "Scene":
                    scenes[func_id] = func_name
        
        # Extract fixtures
        fixtures_elem = self.root.find("Fixtures")
        if fixtures_elem is not None:
            for fixture_elem in fixtures_elem.findall("Fixture"):
                fixtures.append({
                    "id": fixture_elem.get("id"),
                    "name": fixture_elem.get("name")
                })
        
        return TemplateWorkspaceInfo(
            template_path=str(self.template_path),
            available_functions=functions,
            available_scenes=scenes,
            fixtures=fixtures,
            channel_count=512
        )
```

### 3. Create QXW Generator

Create `/home/user/traxxtool/src/core/qxw_generator.py` (use code provided above in "QXW Workspace Generation" section).

### 4. Extend MIDI Generator

Update `/home/user/traxxtool/src/core/midi_generator.py` with light cue methods (use code provided above).

### 5. Create Video Cues Generator

Add to `/home/user/traxxtool/src/core/qxw_generator.py` (or separate file):

```python
import json
from models import LightingCue
from typing import List

class VideoCuesGenerator:
    def __init__(self, lighting_cues: List[LightingCue]):
        self.cues = lighting_cues
    
    def generate(self) -> dict:
        cues_by_id = {}
        
        for cue in self.cues:
            if cue.video_file:
                cue_entry = {
                    "videoFile": cue.video_file,
                    "startTime": cue.start_time_ms,
                    "duration": cue.duration_ms,
                    "fadeIn": cue.fade_in_ms,
                    "fadeOut": cue.fade_out_ms
                }
                
                func_id = cue.qlc_function_id
                if func_id not in cues_by_id:
                    cues_by_id[func_id] = []
                
                cues_by_id[func_id].append(cue_entry)
        
        return {
            "version": "1.0",
            "cues": cues_by_id
        }
    
    def save(self, output_path: str):
        data = self.generate()
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)
```

### 6. Update Compiler

Modify `/home/user/traxxtool/src/core/compiler.py`:

```python
from workspace_loader import TemplateWorkspaceLoader
from qxw_generator import QXWGenerator, VideoCuesGenerator
from midi_generator import MidiGenerator
from models import LightingCue

class St4bCompiler:
    # ... existing code ...
    
    def compile_with_lighting(self, template_qxw_path: str, output_dir: str):
        """Compile with lighting integration."""
        from pathlib import Path
        
        output_dir = Path(output_dir)
        
        # Load template
        loader = TemplateWorkspaceLoader(template_qxw_path)
        template_info = loader.load()
        
        # Extract lighting cues from song markers
        qlc_cues = []
        for marker in self.song_model.guide_markers:
            if marker.type == "light" and marker.qlc_function_id is not None:
                cue = LightingCue(
                    start_time_ms=marker.time_ms,
                    duration_ms=marker.duration,
                    qlc_function_id=marker.qlc_function_id,
                    qlc_function_name=marker.qlc_function_name or "",
                    fade_in_ms=marker.fade_in_ms,
                    fade_out_ms=marker.fade_out_ms,
                    video_file=marker.video_file,
                    crossfade_with_previous=(marker.crossfade_duration_ms > 0),
                    crossfade_duration_ms=marker.crossfade_duration_ms
                )
                qlc_cues.append(cue)
        
        # Sort by start time
        qlc_cues.sort(key=lambda c: c.start_time_ms)
        
        # Generate QXW
        gen = QXWGenerator(template_qxw_path)
        show_name = f"{self.song_model.title}_Lighting"
        show_elem = gen.create_show(show_name, qlc_cues)
        gen.add_show_to_template(show_elem)
        
        output_qxw = output_dir / "final.qxw"
        gen.save(str(output_qxw))
        
        # Generate MIDI with light cues
        midi_gen = MidiGenerator()
        for cue in qlc_cues:
            midi_gen.add_light_cue(cue.start_time_ms, cue.qlc_function_id)
            if cue.crossfade_with_previous:
                midi_gen.add_crossfade_markers(cue.start_time_ms, cue.crossfade_duration_ms)
        
        output_midi = output_dir / "lighting_cues.mid"
        midi_gen.write_file(str(output_midi), bpm=self.song_model.bpm or 120)
        
        # Generate videocues.json
        vcues_gen = VideoCuesGenerator(qlc_cues)
        output_videocues = output_dir / "videocues.json"
        vcues_gen.save(str(output_videocues))
        
        return {
            "qxw": str(output_qxw),
            "midi": str(output_midi),
            "videocues": str(output_videocues)
        }
```

### 7. Update UI for Lighting Marker Editing

When user creates/edits a marker with type "light", show additional UI fields:
- Dropdown: Select QLC+ function (populated from template)
- Spinbox: Fade In (milliseconds)
- Spinbox: Fade Out (milliseconds)
- Textfield: Video File
- Checkbox: Crossfade with previous
- Spinbox: Crossfade Duration (if enabled)

Update state_manager.py to persist these fields.

---

## XML Reference: QXW Show Structure

```xml
<Function type="Show" id="45" name="Song1_Lighting">
  <Speed fade="0" duration="0"/>
  
  <!-- Track 1: Ambient Lighting -->
  <ShowTrack name="Ambient">
    <!-- Fade in from dark to warm over 2 seconds, hold, fade out -->
    <ShowFunction functionID="12" startTime="0" duration="5000" 
                  FadeIn="2000" FadeOut="1000"/>
  </ShowTrack>
  
  <!-- Track 2: Accent Lighting -->
  <ShowTrack name="Accent">
    <!-- Start at 1 second, run for 3 seconds, instant on/off -->
    <ShowFunction functionID="18" startTime="1000" duration="3000"/>
    
    <!-- Second accent cue, crossfade from previous -->
    <ShowFunction functionID="19" startTime="3500" duration="2500"
                  FadeIn="500" FadeOut="500"/>
  </ShowTrack>
  
  <!-- Track 3: Video Sync -->
  <ShowTrack name="VideoSync">
    <ShowFunction functionID="22" startTime="2000" duration="6000"
                  FadeIn="0" FadeOut="0"/>
  </ShowTrack>
</Function>
```

---

## Testing Checklist

- [ ] Load template.qxw without errors
- [ ] Extract function list correctly
- [ ] Create LightingCue objects from guide markers
- [ ] Generate valid QXW with ShowTrack/ShowFunction elements
- [ ] Verify XML structure matches QLC+ expectations
- [ ] MIDI file contains Program Changes on channel 15 at correct times
- [ ] videocues.json has correct structure
- [ ] Load generated final.qxw in QLC+ desktop without errors
- [ ] Shows appear in QLC+ and execute correctly
- [ ] Fade times are respected during playback
- [ ] StageCue receives MIDI PCs and triggers functions
- [ ] Video playback syncs with lighting via videocues.json

---

## Common Pitfalls & Solutions

### 1. Function ID Out of Range
**Problem**: QLC+ function ID exceeds 127, causing MIDI Program Change to fail.
**Solution**: Implement function ID mapping in compiler. Map first 128 unique functions to 0-127 range, or split into multiple MIDI channels.

### 2. XML Parsing Errors
**Problem**: template.qxw has unexpected structure or missing elements.
**Solution**: Add robust error handling in TemplateWorkspaceLoader. Validate XML schema before processing.

### 3. Fade Duration Exceeds Clip Duration
**Problem**: fadeInDuration + fadeOutDuration > duration, causing invalid curves.
**Solution**: In LightingCue validation, ensure fadeIn + fadeOut ≤ duration. Clamp or warn user.

### 4. MIDI Timing Precision
**Problem**: Converted milliseconds to MIDI ticks with rounding errors, causing timing drift.
**Solution**: Use consistent tempo conversion: `ticks = (ms / 1000) * PPQ * (BPM / 60)` with proper rounding.

### 5. Crossfade Logic
**Problem**: Crossfade markers overlap, causing clips to interfere.
**Solution**: Ensure showfunction clips don't overlap. If crossfading, verify cfade_duration < (next_clip_start - current_clip_end).

---

## References

- QLC+ Source: `/home/user/qlcplus/`
- ShowFunction Model: `/home/user/qlcplus/engine/src/showfunction.h`
- ShowManager Backend: `/home/user/qlcplus/qmlui/showmanager.h`
- QML UI: `/home/user/qlcplus/qmlui/qml/showmanager/`
- TraxxTool Source: `/home/user/traxxtool/src/`
- StageCue Server: `/home/user/stagebox/stagecue/server.js`

---

**End of Integration Guide**

This guide should be comprehensive enough for another developer to implement the full TraxxTool ↔ QLC+ integration independently.

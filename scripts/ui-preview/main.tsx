import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { ShiftAgenda, type AgendaShift } from '../../components/schedule/ShiftAgenda';
import { HomeOverview } from '../../components/HomeOverview';
import { colors } from '../../lib/theme';

const shifts: AgendaShift[] = [
  { _id: 'sample-1', dayIndex: 2, startMinutes: 900, endMinutes: 1380, memberName: 'Alex Rivera', profileId: 'sample-a', jobTitle: 'Server', station: 'Main floor', conflict: false },
  { _id: 'sample-2', dayIndex: 2, startMinutes: 960, endMinutes: 1440, memberName: 'Morgan Chen', profileId: 'sample-b', jobTitle: 'Bartender', station: 'Bar', conflict: true },
  { _id: 'sample-3', dayIndex: 2, startMinutes: 1020, endMinutes: 1560, memberName: null, profileId: null, jobTitle: 'Host', station: 'Front desk', conflict: false },
];
function Preview() {
  const [screen, setScreen] = useState<'home' | 'schedule'>('home');
  const [unavailable, setUnavailable] = useState(false);
  const [day, setDay] = useState(2);
  const [message, setMessage] = useState('Select a shift to inspect its action.');
  return <main style={{ minHeight: '100vh', background: colors.background, color: colors.charcoal, fontFamily: 'system-ui, sans-serif', padding: '24px 16px', boxSizing: 'border-box' }}>
    <div style={{ maxWidth: 420, margin: '0 auto' }}>
      <p style={{ fontSize: 11, letterSpacing: 1, color: colors.muted }}>DESIGN PREVIEW · SAMPLE DATA</p>
      <nav style={{ display: 'flex', gap: 8 }}>
        {(['home', 'schedule'] as const).map((name) => <button key={name} aria-pressed={screen === name} onClick={() => { setScreen(name); setMessage('Select a row to inspect its action.'); }} style={{ minHeight: 44, padding: '0 18px', border: `1px solid ${colors.border}`, borderRadius: 8, background: screen === name ? colors.primary : colors.surface, color: screen === name ? colors.buttonText : colors.charcoal }}>{name === 'home' ? 'Home' : 'Schedule'}</button>)}
      </nav>
      <h1 style={{ fontSize: 30, margin: '24px 0 4px' }}>{screen === 'home' ? 'Tonight' : 'Schedule'}</h1>
      <p style={{ fontSize: 14, color: colors.muted, margin: '0 0 24px' }}>{screen === 'home' ? 'The Fox & Vine · Tuesday, September 22' : 'September 20 – 26'}</p>
      {screen === 'home' ? <>
        <label style={{ display: 'flex', gap: 8, alignItems: 'center', minHeight: 44, marginBottom: 16, fontSize: 13 }}><input type="checkbox" checked={unavailable} onChange={(event) => setUnavailable(event.target.checked)} />Show unavailable data</label>
        <HomeOverview palette={colors} readiness={[[ 'Staffing', 100 ], [ 'Setup', 75 ], [ 'Floor', 100 ], [ 'Approvals', 0 ]]} readinessScore={88} readinessUnavailable={unavailable} onOpenArea={(area) => setMessage(`Open ${area}`)} onOpenSchedule={() => setScreen('schedule')} timelineUnavailable={unavailable} timeline={[
          { id: 'sample-arrival', time: '5:30 PM', title: 'Private dining arrival', detail: '24 guests · Main dining room', onPress: () => setMessage('Open private dining event') },
          { id: 'sample-service', time: '6:00 PM', title: 'Evening service', detail: 'Review floor readiness with the team', onPress: () => setMessage('Open evening service') },
        ]} metrics={unavailable ? [['Sales', '—'], ['Labor', '—'], ['Open checks', '—'], ['Active clocks', '—']] : [['Sales', '$12,480.00'], ['Labor', '42h 30m'], ['Open checks', '18'], ['Active clocks', '12']]} />
      </> : <ShiftAgenda shifts={shifts} carryInShifts={[]} selectedDay={day} onDayChange={setDay} days={['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((label, index) => ({ label, date: String(20 + index), today: index === 2 }))} onSelect={(shift) => setMessage(`Edit ${shift.memberName ?? 'open shift'}: ${shift.jobTitle}`)} onCreate={(index) => setMessage(`Create shift for September ${20 + index}`)} />}
      <p role="status" style={{ color: colors.muted, fontSize: 12, lineHeight: 1.6, marginTop: 24 }}>{message}</p>
    </div>
  </main>;
}
createRoot(document.getElementById('root')!).render(<Preview />);

export default function App() {
  return (
    <main className="pixie-stage antialiased" aria-label="Pixie robot landing page">
      <div className="pixie-glow pixie-glow-left" aria-hidden="true" />
      <div className="pixie-glow pixie-glow-right" aria-hidden="true" />

      <h1 className="pixie-wordmark">Pixie</h1>

      <div className="robot-wrap" aria-hidden="true">
        <img
          className="pixie-robot"
          src="/pixie-robot.png"
          alt=""
          draggable="false"
        />
      </div>

      <div className="stage-grain" aria-hidden="true" />
    </main>
  );
}

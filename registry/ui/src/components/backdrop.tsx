import { useEffect, useRef } from "react";

export function Backdrop() {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const context = canvas?.getContext("2d");
    if (!canvas || !context) return;

    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let frame = 0;
    let width = 0;
    let height = 0;
    let lastFrame = 0;

    const resize = () => {
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = canvas.clientWidth;
      height = canvas.clientHeight;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      draw(0);
    };

    const draw = (time: number) => {
      context.clearRect(0, 0, width, height);
      const phase = time * .00028;
      const step = 14;
      for (let band = 0; band < 3; band++) {
        const center = height * (.22 + band * .31);
        for (let line = -3; line <= 3; line++) {
          context.lineWidth = line === 0 ? 1.5 : 1;
          context.strokeStyle = band === 1
            ? `rgba(220, 170, 101, ${line === 0 ? .17 : .065})`
            : `rgba(98, 212, 216, ${line === 0 ? .18 : .075})`;
          context.beginPath();
          for (let x = -step; x <= width + step; x += step) {
            const envelope = Math.sin(Math.PI * Math.min(1, Math.max(0, x / width)));
            const wave = Math.sin(x * .006 + phase + band * 1.7) * 25 + Math.sin(x * .013 - phase * .65 + line) * 9;
            const y = center + line * 17 + wave * envelope;
            if (x === -step) context.moveTo(x, y);
            else context.lineTo(x, y);
          }
          context.stroke();
        }
        const tracer = ((time * .06 + band * width * .37) % (width + 200)) - 100;
        const tracerY = center + Math.sin(tracer * .006 + phase + band * 1.7) * 25;
        context.strokeStyle = band === 1 ? "rgba(220, 170, 101, .45)" : "rgba(98, 212, 216, .50)";
        context.lineWidth = 2;
        context.beginPath();
        context.moveTo(tracer - 36, tracerY);
        context.lineTo(tracer + 36, tracerY);
        context.stroke();
      }
    };

    const animate = (time: number) => {
      if (time - lastFrame >= 40) {
        draw(time);
        lastFrame = time;
      }
      frame = requestAnimationFrame(animate);
    };
    const setMotion = () => {
      cancelAnimationFrame(frame);
      if (motion.matches) draw(0);
      else frame = requestAnimationFrame(animate);
    };

    window.addEventListener("resize", resize);
    motion.addEventListener("change", setMotion);
    resize();
    setMotion();
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", resize);
      motion.removeEventListener("change", setMotion);
    };
  }, []);

  return <canvas className="registry-backdrop" ref={canvasRef} aria-hidden="true" />;
}

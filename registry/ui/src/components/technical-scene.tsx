import { useEffect, useRef, useState } from "react";
import * as THREE from "three";

export type SceneKind = "hero" | "thesis" | "performance" | "language" | "compiler" | "memory" | "systems" | "workflow";

type Props = { kind: SceneKind; label: string; className?: string };
type SceneBuild = { group: THREE.Group; tick: (time: number) => void };

const cyan = 0x60d5df;
const gold = 0xdcae70;
const rose = 0xc684a1;

export function TechnicalScene({ kind, label, className = "" }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const [near, setNear] = useState(false);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const observer = new IntersectionObserver(([entry]) => setNear(entry.isIntersecting), { rootMargin: "180px 0px" });
    observer.observe(host);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const host = hostRef.current;
    if (!host || !near) return;
    let renderer: THREE.WebGLRenderer;
    try {
      renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true, powerPreference: "low-power" });
    } catch {
      return;
    }
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
    renderer.setClearColor(0x000000, 0);
    renderer.domElement.setAttribute("aria-hidden", "true");
    host.appendChild(renderer.domElement);

    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(36, 1, .1, 100);
    camera.position.set(0, 0, 10);
    scene.add(new THREE.AmbientLight(0x9fb9bd, 2.2));
    const key = new THREE.DirectionalLight(0xffffff, 3);
    key.position.set(-3, 4, 7);
    scene.add(key);
    const rim = new THREE.DirectionalLight(cyan, 2.3);
    rim.position.set(4, -2, -4);
    scene.add(rim);

    const { group, tick } = build(kind);
    scene.add(group);
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let pointerX = 0;
    let pointerY = 0;
    let dragging = false;
    let dragX = 0;
    let dragY = 0;
    let lastX = 0;
    let lastY = 0;

    const resize = () => {
      const width = host.clientWidth;
      const height = host.clientHeight;
      if (!width || !height) return;
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
      renderer.setSize(width, height);
      renderer.render(scene, camera);
    };
    const observer = new ResizeObserver(resize);
    observer.observe(host);
    const move = (event: PointerEvent) => {
      const rect = host.getBoundingClientRect();
      pointerX = ((event.clientX - rect.left) / rect.width - .5) * 2;
      pointerY = ((event.clientY - rect.top) / rect.height - .5) * 2;
      if (dragging) {
        dragX += (event.clientX - lastX) * .008;
        dragY += (event.clientY - lastY) * .008;
        lastX = event.clientX;
        lastY = event.clientY;
      }
      if (motion.matches) render(0);
    };
    const down = (event: PointerEvent) => {
      dragging = true;
      lastX = event.clientX;
      lastY = event.clientY;
      host.setPointerCapture(event.pointerId);
      host.classList.add("dragging");
    };
    const up = () => {
      dragging = false;
      host.classList.remove("dragging");
    };
    const render = (time: number) => {
      const seconds = time * .001;
      group.rotation.y += ((motion.matches ? 0 : seconds * .16) + dragX + pointerX * .28 - group.rotation.y) * .055;
      group.rotation.x += (dragY - pointerY * .17 - group.rotation.x) * .055;
      tick(motion.matches ? 0 : seconds);
      renderer.render(scene, camera);
    };
    const setMotion = () => {
      renderer.setAnimationLoop(null);
      if (motion.matches) render(0);
      else renderer.setAnimationLoop(render);
    };
    host.addEventListener("pointermove", move);
    host.addEventListener("pointerdown", down);
    host.addEventListener("pointerup", up);
    host.addEventListener("pointercancel", up);
    motion.addEventListener("change", setMotion);
    resize();
    setMotion();

    return () => {
      renderer.setAnimationLoop(null);
      observer.disconnect();
      motion.removeEventListener("change", setMotion);
      host.removeEventListener("pointermove", move);
      host.removeEventListener("pointerdown", down);
      host.removeEventListener("pointerup", up);
      host.removeEventListener("pointercancel", up);
      const resources = new Set<{ dispose: () => void }>();
      group.traverse((object) => {
        if (object instanceof THREE.Mesh || object instanceof THREE.Line) {
          resources.add(object.geometry);
          const materials = Array.isArray(object.material) ? object.material : [object.material];
          materials.forEach((material) => resources.add(material));
        }
      });
      resources.forEach((resource) => resource.dispose());
      renderer.dispose();
      renderer.forceContextLoss();
      renderer.domElement.remove();
    };
  }, [kind, near]);

  return <div ref={hostRef} className={`foo3d-scene ${className}`} role="img" aria-label={label} data-scene={kind} />;
}

function build(kind: SceneKind): SceneBuild {
  const group = new THREE.Group();
  const moving: THREE.Object3D[] = [];
  const solid = (color: number, opacity = 1) => new THREE.MeshStandardMaterial({
    color, metalness: .45, roughness: .28, transparent: opacity < 1, opacity,
    emissive: color, emissiveIntensity: .12, side: THREE.DoubleSide,
  });
  const wire = (color: number, opacity = .7) => new THREE.MeshBasicMaterial({ color, wireframe: true, transparent: true, opacity });
  const add = (geometry: THREE.BufferGeometry, material: THREE.Material, x = 0, y = 0, z = 0) => {
    const object = new THREE.Mesh(geometry, material);
    object.position.set(x, y, z);
    group.add(object);
    return object;
  };
  const connect = (points: THREE.Vector3[], color = cyan, radius = .018) => {
    add(new THREE.TubeGeometry(new THREE.CatmullRomCurve3(points), 36, radius, 6, false), solid(color, .68));
  };
  const point = (x: number, y: number, z = 0) => new THREE.Vector3(x, y, z);

  if (kind === "hero") {
    const core = add(new THREE.TorusKnotGeometry(1.18, .23, 128, 14, 2, 3), solid(cyan));
    moving.push(core);
    const shell = add(new THREE.IcosahedronGeometry(2.1, 1), wire(cyan, .24));
    shell.rotation.x = .35;
    for (const [index, color] of [cyan, gold, rose].entries()) {
      const ring = add(new THREE.TorusGeometry(2.65 + index * .18, .012, 6, 100), solid(color, .65));
      ring.rotation.set(.7 + index * .32, index * .45, .2);
      moving.push(ring);
    }
  } else if (kind === "thesis") {
    [-2.2, 0, 2.2].forEach((x, index) => {
      const color = [cyan, gold, rose][index];
      const plate = add(new THREE.BoxGeometry(1.35, 1.85, .16), solid(color, .74), x, 0, index === 1 ? .35 : -.2);
      plate.rotation.y = -.3 + index * .3;
      add(new THREE.BoxGeometry(.9, .11, .2), solid(0xe9f0ef), x, .34, .2);
      add(new THREE.BoxGeometry(.66, .07, .2), solid(color), x, 0, .2);
      add(new THREE.BoxGeometry(.78, .07, .2), solid(color), x, -.27, .2);
      moving.push(plate);
    });
    connect([point(-1.5, 0), point(-.7, .15), point(.7, .15), point(1.5, 0)], cyan);
  } else if (kind === "performance") {
    for (let index = 0; index < 12; index++) {
      const height = .45 + (index % 4) * .27;
      const block = add(new THREE.BoxGeometry(.3, height, .35), solid(index < 9 ? gold : cyan), -2.45 + index * .45, -1.25 + height / 2, (index % 3) * -.2);
      moving.push(block);
    }
    const after = add(new THREE.DodecahedronGeometry(.95, 1), solid(cyan), 1.1, .7, .2);
    moving.push(after);
    add(new THREE.TorusGeometry(1.48, .018, 6, 90), wire(cyan, .75), 1.1, .7, .2);
    connect([point(-2.25, .5), point(-1.25, 1.2), point(.1, 1.2), point(1.1, .7)], gold);
  } else if (kind === "language") {
    for (let index = 0; index < 5; index++) {
      const plate = add(new THREE.BoxGeometry(3.8 - index * .24, .38, .12), solid(index % 2 ? gold : cyan, .88), -.25 + index * .1, 1.35 - index * .65, index * .3);
      plate.rotation.y = -.18;
      add(new THREE.BoxGeometry(.6 + index * .14, .045, .14), solid(0xe7eeee), -1.15, 1.35 - index * .65, index * .3 + .1);
      moving.push(plate);
    }
    add(new THREE.IcosahedronGeometry(.42, 0), wire(rose, .8), 2.15, -.6, .75);
  } else if (kind === "compiler") {
    const positions = [point(-2.7, .9), point(-1.4, -.5, .4), point(0, .9, .8), point(1.4, -.5, .4), point(2.6, .9)];
    positions.forEach((position, index) => {
      const node = add(new THREE.OctahedronGeometry(index === 2 ? .55 : .38), solid(index === 2 ? gold : cyan), position.x, position.y, position.z);
      moving.push(node);
      if (index) connect([positions[index - 1], position], index === 2 ? gold : cyan, .024);
    });
    connect([positions[3], point(2.6, -1.15, -.3)], rose, .018);
    add(new THREE.OctahedronGeometry(.22), solid(rose), 2.6, -1.15, -.3);
  } else if (kind === "memory") {
    const rings = [1.1, 1.55, 2.05].map((radius, index) => {
      const ring = add(new THREE.TorusGeometry(radius, .05, 8, 90), solid([cyan, gold, rose][index], .75));
      ring.rotation.x = .75 + index * .18;
      return ring;
    });
    moving.push(...rings);
    const payload = add(new THREE.BoxGeometry(.47, .47, .47), solid(0xe8efef));
    moving.push(payload);
    add(new THREE.IcosahedronGeometry(.68, 0), wire(cyan, .6));
  } else if (kind === "systems") {
    const center = add(new THREE.IcosahedronGeometry(.95, 1), solid(cyan));
    moving.push(center);
    for (let index = 0; index < 10; index++) {
      const angle = index * Math.PI * 2 / 10;
      const x = Math.cos(angle) * 2.55;
      const y = Math.sin(angle) * 1.68;
      const z = Math.sin(angle * 2) * .8;
      add(new THREE.OctahedronGeometry(.23 + index % 3 * .06), solid(index % 3 ? gold : rose), x, y, z);
      connect([point(0, 0), point(x, y, z)], cyan, .012);
    }
    add(new THREE.TorusGeometry(2.75, .012, 5, 96), wire(cyan, .3));
  } else {
    for (let index = 0; index < 5; index++) {
      const x = -2.5 + index * 1.22;
      const y = -1 + index * .5;
      const node = add(new THREE.BoxGeometry(.83, .83, .83), solid(index === 4 ? cyan : index % 2 ? gold : rose), x, y, index * .2);
      node.rotation.set(.18, -.24, .08);
      moving.push(node);
      if (index) connect([point(x - 1.22, y - .5, (index - 1) * .2), point(x, y, index * .2)], cyan, .02);
    }
  }

  const bases = moving.map((object) => ({ y: object.position.y, rotationZ: object.rotation.z }));
  return {
    group,
    tick: (time) => {
      moving.forEach((object, index) => {
        if (kind === "memory" && index === 3) {
          object.position.set(Math.cos(time * .55) * 1.55, Math.sin(time * .55) * 1.15, .5);
        } else {
          object.rotation.z = bases[index].rotationZ + Math.sin(time * .45 + index * .6) * .07;
          object.position.y = bases[index].y + Math.sin(time * .65 + index * .9) * .06;
        }
      });
    },
  };
}

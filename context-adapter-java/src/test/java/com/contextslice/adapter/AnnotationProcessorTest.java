package com.contextslice.adapter;

import com.contextslice.adapter.ir.IrModel.IrSymbol;
import com.contextslice.adapter.static_analysis.AnnotationProcessor;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class AnnotationProcessorTest {

    private final AnnotationProcessor processor = new AnnotationProcessor();

    private IrSymbol symbol(String id, String... annotations) {
        IrSymbol s = new IrSymbol();
        s.id = id;
        s.annotations = List.of(annotations);
        s.isFramework = false;
        return s;
    }

    @Test
    void serviceAnnotationSetsFrameworkTrue() {
        IrSymbol s = symbol("java::com.example.StripeOrderService", "@Service");
        processor.process(List.of(s));
        assertTrue(s.isFramework);
    }

    @Test
    void restControllerAnnotationSetsFrameworkTrue() {
        IrSymbol s = symbol("java::com.example.OrderController", "@RestController");
        processor.process(List.of(s));
        assertTrue(s.isFramework);
    }

    @Test
    void transactionalOnMethodDoesNotSetFrameworkTrue() {
        // @Transactional on a method does not make the METHOD a framework symbol
        IrSymbol s = symbol("java::com.example.StripeOrderService::createOrder(OrderRequest)", "@Override", "@Transactional");
        processor.process(List.of(s));
        // @Transactional alone is not in FRAMEWORK_ANNOTATIONS set — method body is app code
        // Note: @Transactional IS NOT in the framework annotation set for methods
        assertFalse(s.isFramework);
    }

    @Test
    void pojoBeanWithNoAnnotationsIsNotFramework() {
        IrSymbol s = symbol("java::com.example.OrderRequest");
        s.annotations = new ArrayList<>();
        processor.process(List.of(s));
        assertFalse(s.isFramework);
    }

    @Test
    void springBootApplicationAnnotationSetsFrameworkTrue() {
        IrSymbol s = symbol("java::com.example.App", "@SpringBootApplication");
        processor.process(List.of(s));
        assertTrue(s.isFramework);
    }

    @Test
    void orgSpringframeworkPackageIsFramework() {
        IrSymbol s = symbol("java::org.springframework.web.servlet.DispatcherServlet");
        s.annotations = new ArrayList<>();
        processor.process(List.of(s));
        assertTrue(s.isFramework);
    }

    @Test
    void appPackageIsNotFrameworkByDefault() {
        IrSymbol s = symbol("java::com.contextslice.fixture.OrderService");
        s.annotations = new ArrayList<>();
        processor.process(List.of(s));
        assertFalse(s.isFramework);
    }
}
